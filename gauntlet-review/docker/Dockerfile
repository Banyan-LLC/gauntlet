# Pinned base by digest (replace with the resolved digest at build time; recorded in the manifest).
FROM debian:bookworm-slim@sha256:REPLACE_WITH_PINNED_DIGEST

# Arbitrary-UID compatible: no fixed USER; the runner passes --user <hostuid>:<hostgid>.
# World-readable/executable install locations so any UID can run.
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install the PINNED Codex CLI. Mechanism (npm global or release artifact) is finalized in
# Task 5 Step 0's sibling investigation; pin the exact version and record its provenance.
# COPY the pinned CLI in or RUN the pinned installer here.

COPY entrypoint.py /gauntlet/entrypoint.py
RUN chmod 0755 /gauntlet/entrypoint.py

ENTRYPOINT ["python3", "/gauntlet/entrypoint.py"]
