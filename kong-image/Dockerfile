# Kong Gateway OSS 3.9.1 (the last OSS release - Kong publishes no newer OSS
# image, so upstream will not pick up OS security fixes) + the Ubuntu security
# updates available at build time. Same Kong, same config, same non-root user;
# only OS packages change. CI rebuilds it and fails on any fixable HIGH/CRITICAL.
FROM kong:3.9.1

USER 0
# hadolint ignore=DL3005
RUN apt-get update \
    && apt-get -y --no-install-recommends upgrade \
    && rm -rf /var/lib/apt/lists/*
# 1001 = the image's own "kong" user (numeric so Kubernetes can verify non-root)
USER 1001

HEALTHCHECK --interval=10s --timeout=5s --retries=10 CMD ["kong", "health"]
