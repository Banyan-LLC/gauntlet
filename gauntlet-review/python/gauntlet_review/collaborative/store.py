"""Checked local SQLite history and atomic, scope-bound mutation receipts."""
from __future__ import annotations

import asyncio
import base64
from contextlib import contextmanager
from dataclasses import replace
import hashlib
import os
from pathlib import Path
import sqlite3
import stat

from pydantic import ValidationError

from .contracts import (BytePage,CoreError,EvidenceData,Event,OpenData,Page,Policy,
                        ReceiptRecord,RetryMetadata,StoredResult,StoreView,VerdictData,decode_canonical,
                        decode_event,encode,validate_operator_config)
from .policy import reduce_series

_DDL = (
    "CREATE TABLE meta(schema_version INTEGER NOT NULL,store_version INTEGER NOT NULL,payload_bytes INTEGER NOT NULL)",
    "CREATE TABLE series(id TEXT PRIMARY KEY,repo_id TEXT NOT NULL,repo_binding TEXT NOT NULL,source_ref BLOB NOT NULL,target_ref BLOB NOT NULL,policy_digest TEXT NOT NULL,payload_bytes INTEGER NOT NULL,UNIQUE(repo_id,source_ref,target_ref))",
    "CREATE TABLE events(id TEXT PRIMARY KEY,series_id TEXT NOT NULL REFERENCES series(id),seq INTEGER NOT NULL,store_version INTEGER NOT NULL UNIQUE,revision_id TEXT NOT NULL,kind TEXT NOT NULL,body BLOB NOT NULL,body_sha256 TEXT NOT NULL,UNIQUE(series_id,seq))",
    "CREATE TABLE evidence(id TEXT PRIMARY KEY,series_id TEXT NOT NULL REFERENCES series(id),revision_id TEXT NOT NULL,bytes BLOB NOT NULL,sha256 TEXT NOT NULL)",
    "CREATE TABLE retries(series_scope TEXT NOT NULL,participant TEXT NOT NULL,operation TEXT NOT NULL,key TEXT NOT NULL,request_sha256 TEXT NOT NULL,event_id TEXT NOT NULL REFERENCES events(id),result_store_version INTEGER NOT NULL,result_bytes BLOB NOT NULL,result_sha256 TEXT NOT NULL,PRIMARY KEY(series_scope,participant,operation,key))",
)
_COLUMNS = {
    "meta":("schema_version","store_version","payload_bytes"),
    "series":("id","repo_id","repo_binding","source_ref","target_ref","policy_digest","payload_bytes"),
    "events":("id","series_id","seq","store_version","revision_id","kind","body","body_sha256"),
    "evidence":("id","series_id","revision_id","bytes","sha256"),
    "retries":("series_scope","participant","operation","key","request_sha256","event_id","result_store_version","result_bytes","result_sha256"),
}
_APPLICATION_ID = 0x474D4331


def _corrupt(reason):
    raise CoreError("CORRUPT_STATE",detail={"reason":reason})


def _integer(value):
    return type(value) is int and 0<=value<=2**53-1


def _row_event(row):
    return Event(row["id"],row["seq"],row["revision_id"],row["kind"],row["body"],
                 row["body_sha256"],row["store_version"])


def _retry_metadata(row):
    try:
        return RetryMetadata.model_validate({key:row[key] for key in _COLUMNS["retries"] if key!="result_bytes"},
                                             strict=True).model_dump(mode="python")
    except (ValueError,TypeError,ValidationError) as error:
        raise CoreError("CORRUPT_STATE",detail={"reason":"retry_metadata"}) from error


def _cursor(binding,offset):
    value={**binding,"offset":offset}
    value["digest"]=hashlib.sha256(encode(value)).hexdigest()
    return base64.urlsafe_b64encode(encode(value)).decode("ascii")


def history_items(series):
    return tuple({"id":event.id,"seq":event.seq,"kind":event.kind,"revision_id":event.revision_id,
                  "snapshot_digest":decode_event(event).snapshot_digest,"length":len(event.body),
                  "sha256":event.body_digest,"artifact_id":event.id} for event in series.events)


def paginate(items,*,binding,cursor,limit,mapper=None):
    if type(limit) is not int or not 1<=limit<=100:
        raise CoreError("INVALID_ARGUMENT",detail={"reason":"page_limit"})
    offset=0
    if cursor is not None:
        try:
            if type(cursor) is not str or len(cursor)>4096:
                raise ValueError("cursor length")
            raw=base64.b64decode(cursor,altchars=b"-_",validate=True)
            if base64.urlsafe_b64encode(raw).decode("ascii")!=cursor:
                raise ValueError("noncanonical cursor")
            value=decode_canonical(raw)
            if type(value) is not dict or set(value)!=set(binding)|{"offset","digest"}:
                raise ValueError("cursor shape")
            digest=value.pop("digest")
            if hashlib.sha256(encode(value)).hexdigest()!=digest or not _integer(value["offset"]):
                raise ValueError("cursor integrity")
            if value["store_version"]!=binding["store_version"]:
                raise CoreError("CONFLICT",True,{"reason":"cursor_version_changed"})
            if {key:value[key] for key in binding}!=binding:
                raise ValueError("cursor binding")
            offset=value["offset"]
        except CoreError as error:
            if error.code=="CONFLICT":
                raise
            raise CoreError("INVALID_ARGUMENT",detail={"reason":"invalid_cursor"}) from error
        except (ValueError,TypeError,KeyError,UnicodeError) as error:
            raise CoreError("INVALID_ARGUMENT",detail={"reason":"invalid_cursor"}) from error
    items=tuple(items)
    if offset>len(items):
        raise CoreError("INVALID_ARGUMENT",detail={"reason":"cursor_offset"})
    rows=[]
    for original in items[offset:offset+limit]:
        row=original if mapper is None else mapper(original)
        candidate=rows+[row]
        # Reserve a bounded envelope/cursor allowance. Core also checks its
        # complete canonical envelope, including these exact rows, before return.
        if len(encode({"items":candidate}))+4096>80*1024:
            if not rows:
                raise CoreError("LIMIT_EXCEEDED",detail={"limit":"listing_row_bytes"})
            break
        rows=candidate
    end=offset+len(rows)
    return Page(tuple(rows),None if end==len(items) else _cursor(binding,end),end==len(items),binding["store_version"])


class Store:
    FILENAME="collaborative-v1.sqlite3"

    @classmethod
    def open(cls,config,repo_binding,*,policy=None):
        value=cls()
        value.config=validate_operator_config(config)
        value.repo_binding=os.path.normcase(str(Path(repo_binding).resolve(strict=True)))
        value.policy=policy or Policy()
        value.path=value.config.state_dir/value.FILENAME
        value.closed=False
        value._lock=asyncio.Lock()
        value._checked_paths()
        with value._connection(create=True) as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                tables={row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if not tables:
                    if connection.execute("PRAGMA application_id").fetchone()[0] not in (0,_APPLICATION_ID):
                        raise CoreError("UNSUPPORTED_SCHEMA",detail={"reason":"foreign_database"})
                    for statement in _DDL:
                        connection.execute(statement)
                    connection.execute("INSERT INTO meta VALUES(1,0,0)")
                    connection.execute(f"PRAGMA application_id={_APPLICATION_ID}")
                    connection.execute("PRAGMA user_version=1")
                value._schema(connection)
                checks=connection.execute("PRAGMA integrity_check").fetchall()
                if len(checks)!=1 or checks[0][0]!="ok":
                    _corrupt("sqlite_integrity")
                if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
                    _corrupt("foreign_key_integrity")
                value._read_view(connection)
                connection.execute("COMMIT")
            except BaseException:
                if connection.in_transaction:
                    connection.execute("ROLLBACK")
                raise
            if connection.execute("PRAGMA journal_mode=DELETE").fetchone()[0].lower()!="delete":
                raise CoreError("STORAGE_ERROR",detail={"reason":"journal_mode_unavailable"})
        return value

    def __enter__(self):
        return self

    def __exit__(self,*_):
        self.close()

    def close(self):
        self.closed=True

    def _checked_paths(self):
        state=self.config.state_dir
        try:
            for path in reversed((state,*state.parents)):
                info=path.lstat()
                if stat.S_ISLNK(info.st_mode) or getattr(info,"st_file_attributes",0)&0x400:
                    raise CoreError("CONFIGURATION_ERROR",detail={"reason":"redirected_state_component"})
                if not stat.S_ISDIR(info.st_mode):
                    raise CoreError("CONFIGURATION_ERROR",detail={"reason":"state_component_not_directory"})
            resolved=state.resolve(strict=True)
            if resolved.is_relative_to(self.config.repo_path.resolve(strict=True)) or resolved.is_relative_to(Path(self.repo_binding)):
                raise CoreError("CONFIGURATION_ERROR",detail={"reason":"state_inside_repository"})
            info=state.stat()
            if os.name=="posix" and (info.st_uid!=os.getuid() or stat.S_IMODE(info.st_mode)&0o077):
                raise CoreError("CONFIGURATION_ERROR",detail={"reason":"state_must_be_private"})
            for suffix in ("","-journal","-wal","-shm"):
                path=Path(str(self.path)+suffix)
                try:
                    info=path.lstat()
                except FileNotFoundError:
                    continue
                if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)
                        or getattr(info,"st_file_attributes",0)&0x400):
                    raise CoreError("CONFIGURATION_ERROR",detail={"reason":"redirected_or_nonregular_database"})
        except CoreError:
            raise
        except FileNotFoundError as error:
            raise CoreError("CONFIGURATION_ERROR",detail={"reason":"state_or_repository_missing"}) from error
        except OSError as error:
            raise CoreError("CONFIGURATION_ERROR",detail={"reason":"state_path_access_denied"}) from error

    @contextmanager
    def _connection(self,*,create=False,read=False):
        if self.closed:
            raise CoreError("STORAGE_ERROR",detail={"reason":"store_closed"})
        self._checked_paths()
        connection=None
        try:
            target=str(self.path) if create else self.path.resolve().as_uri()+"?mode=rw"
            connection=sqlite3.connect(target,uri=not create,timeout=2,isolation_level=None)
            connection.row_factory=sqlite3.Row
            connection.execute("PRAGMA busy_timeout=2000")
            connection.execute("PRAGMA foreign_keys=ON")
            connection.execute("PRAGMA synchronous=FULL")
            if read:
                connection.execute("BEGIN")
            yield connection
            if read:
                connection.execute("COMMIT")
        except sqlite3.OperationalError as error:
            if "locked" in str(error).lower() or "busy" in str(error).lower():
                raise CoreError("LOCK_TIMEOUT",True,{"reason":"sqlite_lock_timeout"}) from error
            raise CoreError("STORAGE_ERROR",detail={"reason":"sqlite_operation_failed"}) from error
        except sqlite3.DatabaseError as error:
            raise CoreError("CORRUPT_STATE",detail={"reason":"sqlite_database_invalid"}) from error
        except OSError as error:
            raise CoreError("STORAGE_ERROR",True,{"reason":"storage_outcome_uncertain"}) from error
        finally:
            if connection is not None:
                try:
                    if connection.in_transaction:
                        connection.execute("ROLLBACK")
                finally:
                    connection.close()

    @staticmethod
    def _schema(connection):
        tables={row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if tables!=set(_COLUMNS) or connection.execute("PRAGMA user_version").fetchone()[0]!=1:
            raise CoreError("UNSUPPORTED_SCHEMA",detail={"reason":"schema_version_or_tables"})
        if connection.execute("PRAGMA application_id").fetchone()[0]!=_APPLICATION_ID:
            raise CoreError("UNSUPPORTED_SCHEMA",detail={"reason":"database_application"})
        for table,columns in _COLUMNS.items():
            # Table identifiers are fixed module constants, never request data.
            if tuple(row[1] for row in connection.execute(f"PRAGMA table_info({table})"))!=columns:
                raise CoreError("UNSUPPORTED_SCHEMA",detail={"reason":"schema_columns"})
        # Column names alone miss removed uniqueness/foreign-key constraints.
        expected={statement.split("(",1)[0].split()[-1]:" ".join(statement.split()).lower() for statement in _DDL}
        for row in connection.execute("SELECT name,sql FROM sqlite_master WHERE type='table'"):
            if " ".join(row["sql"].split()).lower()!=expected[row["name"]]:
                raise CoreError("UNSUPPORTED_SCHEMA",detail={"reason":"schema_definition"})
        if connection.execute("SELECT 1 FROM sqlite_master WHERE type IN ('trigger','view')").fetchone():
            raise CoreError("UNSUPPORTED_SCHEMA",detail={"reason":"unexpected_schema_objects"})

    def _series_row(self,connection):
        row=connection.execute("SELECT * FROM series WHERE repo_id=? AND source_ref=? AND target_ref=?",
            (self.config.repository_id,self.config.source_ref,self.config.target_ref)).fetchone()
        if row is not None and (row["repo_binding"]!=self.repo_binding or row["policy_digest"]!=self.policy.digest):
            raise CoreError("CONFIGURATION_MISMATCH",detail={"reason":"persisted_repository_or_policy"})
        return row

    @staticmethod
    def _accounting(connection):
        totals={}
        evidence={}
        for row in connection.execute("SELECT series_id,length(body) AS n FROM events"):
            totals[row["series_id"]]=totals.get(row["series_id"],0)+row["n"]
        for row in connection.execute("SELECT series_id,length(bytes) AS n FROM evidence"):
            totals[row["series_id"]]=totals.get(row["series_id"],0)+row["n"]
            evidence[row["series_id"]]=evidence.get(row["series_id"],0)+row["n"]
        for row in connection.execute("SELECT retries.*,events.series_id FROM retries JOIN events ON events.id=retries.event_id"):
            if type(row["result_bytes"]) is not bytes:
                _corrupt("receipt_storage_type")
            size=len(row["result_bytes"])+len(encode(_retry_metadata(row)))
            totals[row["series_id"]]=totals.get(row["series_id"],0)+size
        return sum(totals.values()),totals,evidence

    def _read_view(self,connection):
        self._schema(connection)
        rows=connection.execute("SELECT * FROM meta").fetchall()
        if len(rows)!=1 or rows[0]["schema_version"]!=1:
            raise CoreError("UNSUPPORTED_SCHEMA",detail={"reason":"schema_metadata"})
        meta=rows[0]
        if not _integer(meta["store_version"]) or not _integer(meta["payload_bytes"]):
            _corrupt("store_counters")
        series=self._series_row(connection)  # binding precedes every retry path
        result=None
        if series is not None:
            events=tuple(_row_event(row) for row in connection.execute(
                "SELECT * FROM events WHERE series_id=? ORDER BY seq",(series["id"],)))
            for event in events:
                body=decode_event(event)
                if body.series_scope!=self.config.series_scope or body.review_id!=series["id"]:
                    _corrupt("event_series_scope")
            result=reduce_series(events)
            header=result.snapshot.header
            if (header["repository_id"]!=self.config.repository_id or header["policy_digest"]!=self.policy.digest
                    or header["source_ref_b64"]!=base64.b64encode(self.config.source_ref).decode("ascii")
                    or header["target_ref_b64"]!=base64.b64encode(self.config.target_ref).decode("ascii")):
                _corrupt("snapshot_series_configuration")
            expected_evidence={}
            for event in events:
                if event.kind=="record_evidence":
                    body=decode_event(event)
                    data=EvidenceData.model_validate(body.data,strict=True)
                    if data.content.kind=="inline":
                        expected_evidence[data.evidence_id]=(event.revision_id,data.content.length,data.content.sha256)
            seen=set()
            for row in connection.execute("SELECT * FROM evidence WHERE series_id=?",(series["id"],)):
                if type(row["bytes"]) is not bytes or hashlib.sha256(row["bytes"]).hexdigest()!=row["sha256"]:
                    raise CoreError("DIGEST_MISMATCH",detail={"reason":"evidence_body"})
                if row["id"] not in expected_evidence or expected_evidence[row["id"]]!=(row["revision_id"],len(row["bytes"]),row["sha256"]):
                    _corrupt("evidence_ownership")
                seen.add(row["id"])
            if seen!=set(expected_evidence):
                _corrupt("missing_evidence_body")
        aggregate,totals,evidence=self._accounting(connection)
        if aggregate!=meta["payload_bytes"]:
            _corrupt("store_payload_accounting")
        for row in connection.execute("SELECT id,payload_bytes FROM series"):
            if not _integer(row["payload_bytes"]) or row["payload_bytes"]!=totals.get(row["id"],0):
                _corrupt("series_payload_accounting")
        versions=connection.execute("SELECT count(*),count(DISTINCT store_version),min(store_version),max(store_version) FROM events").fetchone()
        if versions[0]!=meta["store_version"] or versions[1]!=meta["store_version"] or (versions[0] and (versions[2]!=1 or versions[3]!=meta["store_version"])):
            _corrupt("global_event_versions")
        if result is not None:
            result=replace(result,store_version=meta["store_version"],payload_bytes=totals.get(series["id"],0),
                           evidence_bytes=evidence.get(series["id"],0))
        return StoreView(meta["store_version"],result,aggregate)

    def read_series(self):
        with self._connection(read=True) as connection:
            return self._read_view(connection).series

    def version(self):
        with self._connection(read=True) as connection:
            return self._read_view(connection).store_version

    def read_view(self):
        with self._connection(read=True) as connection:
            return self._read_view(connection)

    def inspect(self,action):
        """Render one response from one observed read transaction/version."""
        with self._connection(read=True) as connection:
            view=self._read_view(connection)
            def artifact(review_id,revision_id,artifact_id,offset,length,*,evidence=False):
                return self._read_artifact(connection,view,review_id,revision_id,artifact_id,offset,length,evidence=evidence)
            return action(view,artifact)

    def _verify_receipt(self,row,event,current_version,scope,request_digest):
        raw=row["result_bytes"]
        if type(raw) is not bytes or hashlib.sha256(raw).hexdigest()!=row["result_sha256"]:
            raise CoreError("DIGEST_MISMATCH",detail={"reason":"retry_receipt"})
        try:
            receipt=ReceiptRecord.model_validate(decode_canonical(raw),strict=True)
        except (ValueError,TypeError,ValidationError) as error:
            raise CoreError("CORRUPT_STATE",detail={"reason":"receipt_shape"}) from error
        body=decode_event(event)
        if (receipt.event_id!=event.id or receipt.operation!=event.kind or receipt.review_id!=body.review_id
                or receipt.revision_id!=event.revision_id or receipt.snapshot_digest!=body.snapshot_digest
                or receipt.series_scope!=scope or body.series_scope!=scope or receipt.request_digest!=request_digest
                or body.request_digest!=request_digest or receipt.store_version!=event.store_version
                or row["result_store_version"]!=event.store_version or event.store_version>current_version
                or receipt.operation!=row["operation"] or receipt.observation.model_dump(mode="json")!=body.data.get("observation")):
            _corrupt("receipt_event_binding")
        if event.kind=="open_review":
            data=OpenData.model_validate(body.data,strict=True)
            if receipt.result!={"accepted":True,"change_count":len(data.snapshot.changes),"manifest_digest":body.snapshot_digest}:
                _corrupt("open_receipt_result")
        elif event.kind=="record_evidence":
            data=EvidenceData.model_validate(body.data,strict=True)
            expected={"accepted":True,"evidence_id":data.evidence_id,"producer":data.producer,
                      "origin":data.origin,"content":data.content.model_dump(mode="json")}
            if receipt.result!=expected:
                _corrupt("evidence_receipt_result")
            if data.producer!=row["participant"]:
                _corrupt("evidence_producer_binding")
        elif event.kind=="submit_review":
            data=VerdictData.model_validate(body.data,strict=True)
            expected={"accepted":True,"normalized_verdict":data.normalized_verdict,
                      "accepted_round":data.accepted_round,"new_finding_ids":[entry.record.id for entry in data.recommendations]}
            if receipt.result!=expected or data.reviewer!=row["participant"]:
                _corrupt("verdict_receipt_result")
        return receipt

    def _lookup(self,connection,view,scope,participant,operation,key,request_digest):
        self._series_row(connection)
        if scope!=self.config.series_scope or participant!=self.config.participant:
            raise CoreError("CONFIGURATION_MISMATCH",detail={"reason":"retry_scope_or_participant"})
        row=connection.execute("SELECT * FROM retries WHERE series_scope=? AND participant=? AND operation=? AND key=?",
            (scope,participant,operation,key)).fetchone()
        if row is None:
            return None
        if row["request_sha256"]!=request_digest:
            raise CoreError("CONFLICT",True,{"reason":"idempotency_key_content_changed"})
        event_row=connection.execute("SELECT * FROM events WHERE id=?",(row["event_id"],)).fetchone()
        if event_row is None or view.series is None or event_row["series_id"]!=view.series.id:
            _corrupt("retry_event_ownership")
        event=_row_event(event_row)
        self._verify_receipt(row,event,view.store_version,scope,request_digest)
        return StoredResult(event.id,row["result_bytes"],event.store_version,True)

    def lookup_retry(self,series_scope,participant,operation,key,request_digest):
        with self._connection(read=True) as connection:
            view=self._read_view(connection)
            return self._lookup(connection,view,series_scope,participant,operation,key,request_digest)

    @staticmethod
    def _commit(connection):
        connection.execute("COMMIT")

    async def mutate(self,series_scope,participant,operation,key,request_digest,expected_version,build,checkpoint):
        await checkpoint()
        try:
            await asyncio.wait_for(self._lock.acquire(),timeout=2)
        except TimeoutError as error:
            raise CoreError("LOCK_TIMEOUT",True,{"reason":"connection_lock_timeout"}) from error
        try:
            with self._connection() as connection:
                connection.execute("BEGIN IMMEDIATE")
                view=self._read_view(connection)
                replay=self._lookup(connection,view,series_scope,participant,operation,key,request_digest)
                if replay is not None:
                    connection.execute("ROLLBACK")
                    return replay
                if not _integer(expected_version) or view.store_version!=expected_version:
                    raise CoreError("CONFLICT",True,{"reason":"store_version_changed"})
                mutation=await build(view)
                await checkpoint()
                event=mutation.event
                body=decode_event(event)
                sequence=1 if view.series is None else len(view.series.events)+1
                if (event.kind!=operation or event.seq!=sequence or event.store_version!=view.store_version+1
                        or body.series_scope!=series_scope or body.request_digest!=request_digest
                        or body.revision_id!=event.revision_id or (view.series and body.review_id!=view.series.id)):
                    _corrupt("mutation_event_binding")
                if event.kind=="open_review" and view.series and view.series.revision_count>=self.policy.revisions:
                    raise CoreError("LIMIT_EXCEEDED",detail={"limit":"revisions"})
                # Validate candidate projection before any insertion.
                reduce_series((() if view.series is None else view.series.events)+(event,))
                if view.series is None:
                    if operation!="open_review":
                        _corrupt("first_event_is_not_open")
                    connection.execute("INSERT INTO series VALUES(?,?,?,?,?,?,0)",(body.review_id,
                        self.config.repository_id,self.repo_binding,self.config.source_ref,self.config.target_ref,self.policy.digest))
                metadata={"series_scope":series_scope,"participant":participant,"operation":operation,"key":key,
                          "request_sha256":request_digest,"event_id":event.id,"result_store_version":event.store_version,
                          "result_sha256":hashlib.sha256(mutation.operation_result).hexdigest()}
                receipt_row={**metadata,"result_bytes":mutation.operation_result}
                self._verify_receipt(receipt_row,event,event.store_version,series_scope,request_digest)
                if connection.execute("SELECT 1 FROM events WHERE id=?",(event.id,)).fetchone() or connection.execute("SELECT 1 FROM evidence WHERE id=?",(event.id,)).fetchone():
                    raise CoreError("DIGEST_MISMATCH",detail={"reason":"event_id_collision"})
                evidence_size=0
                evidence_data=None
                if event.kind=="record_evidence":
                    evidence_data=EvidenceData.model_validate(body.data,strict=True)
                    if evidence_data.content.kind=="inline":
                        if type(mutation.evidence_body) is not bytes:
                            _corrupt("missing_mutation_evidence")
                        evidence_size=len(mutation.evidence_body)
                        if (evidence_size!=evidence_data.content.length or hashlib.sha256(mutation.evidence_body).hexdigest()!=evidence_data.content.sha256):
                            raise CoreError("DIGEST_MISMATCH",detail={"reason":"mutation_evidence"})
                    elif mutation.evidence_body is not None:
                        _corrupt("external_evidence_has_body")
                elif mutation.evidence_body is not None:
                    _corrupt("unexpected_evidence_body")
                charge=len(event.body)+len(mutation.operation_result)+len(encode(metadata))+evidence_size
                current=view.series.payload_bytes if view.series else 0
                current_evidence=view.series.evidence_bytes if view.series else 0
                for name,used,limit in (("series_payload_bytes",current+charge,self.policy.series_payload_bytes),
                                       ("store_payload_bytes",view.store_payload_bytes+charge,self.policy.store_payload_bytes),
                                       ("evidence_series_bytes",current_evidence+evidence_size,self.policy.evidence_series_bytes),
                                       ("evidence_call_bytes",evidence_size,self.policy.evidence_call_bytes)):
                    if used>limit:
                        raise CoreError("LIMIT_EXCEEDED",detail={"limit":name})
                connection.execute("INSERT INTO events VALUES(?,?,?,?,?,?,?,?)",(event.id,body.review_id,event.seq,
                    event.store_version,event.revision_id,event.kind,event.body,event.body_digest))
                if evidence_data and evidence_data.content.kind=="inline":
                    if evidence_data.evidence_id==event.id or connection.execute("SELECT 1 FROM events WHERE id=?",(evidence_data.evidence_id,)).fetchone():
                        raise CoreError("DIGEST_MISMATCH",detail={"reason":"evidence_id_collision"})
                    connection.execute("INSERT INTO evidence VALUES(?,?,?,?,?)",(evidence_data.evidence_id,body.review_id,
                        event.revision_id,mutation.evidence_body,evidence_data.content.sha256))
                connection.execute("INSERT INTO retries VALUES(?,?,?,?,?,?,?,?,?)",tuple(receipt_row[key] for key in _COLUMNS["retries"]))
                connection.execute("UPDATE series SET payload_bytes=payload_bytes+? WHERE id=?",(charge,body.review_id))
                connection.execute("UPDATE meta SET store_version=?,payload_bytes=payload_bytes+?",(event.store_version,charge))
                self._read_view(connection)
                await checkpoint()
                # No suspension from the last cancellation check through COMMIT.
                self._commit(connection)
                return StoredResult(event.id,mutation.operation_result,event.store_version,False)
        finally:
            self._lock.release()

    def read_page(self,review_id,revision_id,view,cursor,limit):
        with self._connection(read=True) as connection:
            state=self._read_view(connection)
            series=state.series
            if series is None or series.id!=review_id:
                raise CoreError("NOT_FOUND",detail={"reason":"review"})
            revisions={event.revision_id:decode_event(event).snapshot_digest for event in series.events if event.kind=="open_review"}
            if revision_id not in revisions or view!="history":
                raise CoreError("NOT_FOUND",detail={"reason":"revision_or_view"})
            items=history_items(series)
            return paginate(items,binding={"review_id":review_id,"revision_id":revision_id,
                "snapshot_digest":revisions[revision_id],"view":view,"store_version":state.store_version},cursor=cursor,limit=limit)

    def read_artifact(self,review_id,revision_id,artifact_id,offset,length,*,evidence=False):
        if type(offset) is not int or offset<0 or type(length) is not int or not 1<=length<=65536:
            raise CoreError("INVALID_ARGUMENT",detail={"reason":"artifact_page"})
        with self._connection(read=True) as connection:
            state=self._read_view(connection)
            return self._read_artifact(connection,state,review_id,revision_id,artifact_id,offset,length,evidence=evidence)

    @staticmethod
    def _read_artifact(connection,state,review_id,revision_id,artifact_id,offset,length,*,evidence=False):
        if type(offset) is not int or not 0<=offset<=2**53-1 or type(length) is not int or not 1<=length<=65536:
            raise CoreError("INVALID_ARGUMENT",detail={"reason":"artifact_page"})
        if state.series is None or state.series.id!=review_id:
            raise CoreError("NOT_FOUND",detail={"reason":"review"})
        if evidence:
            row=connection.execute("SELECT bytes AS body,sha256 AS digest FROM evidence WHERE id=? AND series_id=? AND revision_id=?",
                (artifact_id,review_id,revision_id)).fetchone()
        else:
            row=connection.execute("SELECT body,body_sha256 AS digest FROM events WHERE id=? AND series_id=? AND revision_id=?",
                (artifact_id,review_id,revision_id)).fetchone()
        if row is None:
            raise CoreError("NOT_FOUND",detail={"reason":"artifact"})
        data,digest=row["body"],row["digest"]
        if hashlib.sha256(data).hexdigest()!=digest:
            raise CoreError("DIGEST_MISMATCH",detail={"reason":"artifact_body"})
        if offset>len(data):
            raise CoreError("INVALID_ARGUMENT",detail={"reason":"offset_past_end"})
        end=min(len(data),offset+length)
        return BytePage(data[offset:end],offset,len(data),end==len(data),digest)
