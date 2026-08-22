from gauntlet_review.runconfig import RunConfig, build_create_argv, semantic_profile


def _cfg(**over):
    base = dict(
        image_ref="codex@sha256:dead", platform="linux/arm64", uid=1000, gid=1000,
        cidfile="/run/cid-abc", staging_dir="/run/stg-abc", codex_home="/codex-home",
        tmpfs_dir="/work", verdict_path="/work/verdict.json", schema_path="/codex-home/verdict.schema.json",
        disable_set=["apps", "shell_tool"], run_label="gauntlet-run-abc",
    )
    base.update(over)
    return RunConfig(**base)


def _value_after(argv, flag):
    """Return the value immediately following `flag` in argv, or None if `flag` is absent
    (or has nothing after it). Used to assert flag->value ADJACENCY, not just membership."""
    for i, a in enumerate(argv):
        if a == flag:
            return argv[i + 1] if i + 1 < len(argv) else None
    return None


def test_argv_carries_every_mandatory_security_flag():
    argv = build_create_argv("docker", _cfg())
    assert argv[:2] == ["docker", "create"]
    for token in ["--user", "1000:1000", "--read-only", "--cap-drop", "ALL",
                  "--security-opt", "no-new-privileges", "--pids-limit",
                  "--log-driver", "none", "--platform", "linux/arm64",
                  "--cidfile", "/run/cid-abc", "--label", "gauntlet-run-abc"]:
        assert token in argv, token
    # flag -> value ADJACENCY for the security-critical flags (not just membership)
    assert _value_after(argv, "--user") == "1000:1000"
    assert _value_after(argv, "--ipc") == "private"
    assert _value_after(argv, "--cgroupns") == "private"
    # PID and UTS namespaces are private by DEFAULT on Docker/Podman; Docker rejects the
    # literal "--pid private"/"--uts private", so these flags must not appear at all.
    assert "--pid" not in argv
    assert "--uts" not in argv
    assert "--network" in argv  # egress mode is explicit (open, per spec v1)
    # exactly one user bind mount: the credential staging dir, read-only
    binds = [argv[i + 1] for i, a in enumerate(argv) if a == "-v" or a == "--mount"]
    assert any("/run/stg-abc" in b and "ro" in b for b in binds)
    assert not any("/run/stg-abc" not in b and b.startswith("/") and ":" in b and "tmpfs" not in b for b in binds)


def test_argv_carries_all_codex_hermetic_flags_and_disable_set():
    argv = build_create_argv("docker", _cfg())
    for token in ["--ignore-user-config", "--ignore-rules", "--ephemeral",
                  "--skip-git-repo-check", "-s", "read-only",
                  'web_search="disabled"', 'shell_environment_policy.inherit="none"',
                  "-m", "gpt-5.6-sol", "--output-schema", "--json"]:
        assert token in argv, token
    assert argv[-1] == "-"  # prompt over stdin
    # default-deny: every feature in the set gets a --disable
    assert argv.count("--disable") == 2


def test_never_uses_host_namespaces_or_privileged():
    argv = build_create_argv("docker", _cfg())
    # no host-namespace sharing: --ipc/--cgroupns must never carry "host"
    for flag in ("--ipc", "--cgroupns"):
        assert _value_after(argv, flag) != "host"
    # --pid and --uts must not be present with any value at all (private by default;
    # Docker rejects the literal "--pid private"/"--uts private")
    assert "--pid" not in argv
    assert "--uts" not in argv
    assert "--privileged" not in argv


def test_semantic_profile_placeholders_make_per_run_values_stable():
    a = semantic_profile(_cfg(cidfile="/run/cid-1", staging_dir="/run/stg-1", run_label="run-1", uid=1000, gid=1000))
    b = semantic_profile(_cfg(cidfile="/run/cid-2", staging_dir="/run/stg-2", run_label="run-2", uid=1000, gid=1000))
    assert a == b  # differ only in per-run values -> identical semantic profile


def test_semantic_profile_changes_when_a_security_value_changes():
    base = semantic_profile(_cfg())
    weakened = semantic_profile(_cfg(pids_limit=999999))
    assert base != weakened


def test_semantic_profile_differs_when_image_ref_changes():
    # image_ref is the pinned image digest -- the most security-critical value -- and must
    # appear verbatim in the template, not be placeholder-ized away.
    a = semantic_profile(_cfg(image_ref="codex@sha256:aaaa"))
    b = semantic_profile(_cfg(image_ref="codex@sha256:bbbb"))
    assert a != b
