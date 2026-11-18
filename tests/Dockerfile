FROM debian:12.8-slim
RUN apt-get update -q && apt-get install -yq --no-install-recommends \
      bash git curl ca-certificates shellcheck nftables python3 python3-yaml \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /repo
CMD ["bash", "tests/run.sh"]
