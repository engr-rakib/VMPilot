FROM node:22-bookworm-slim AS deps

# Build deps for node-pty native module
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force


FROM node:22-bookworm-slim AS runtime

# CLI tooling the VMPilot scripts expect inside the terminal
ARG TERRAFORM_VERSION=1.9.8
ARG GOVC_VERSION=v0.45.0
ARG SOPS_VERSION=v3.9.2
ARG AGE_VERSION=v1.2.1

COPY --from=deps /app/node_modules /app/node_modules
COPY package.json /app/package.json
COPY src /app/src
COPY scripts /app/scripts

# Downloads can be slow; retry and give generous timeouts.
ARG CURL_FLAGS="-fsSL --retry 3 --retry-delay 2 --max-time 300"
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash curl unzip jq git ca-certificates openssh-client sudo \
    && rm -rf /var/lib/apt/lists/* \
    && arch=$(uname -m) \
    && case "$arch" in \
         x86_64)  TARGET="amd64"; govc_arch="x86_64";; \
         aarch64) TARGET="arm64"; govc_arch="arm64";; \
         *) echo "unsupported arch: $arch" >&2; exit 1;; \
       esac \
    && curl $CURL_FLAGS -o /tmp/terraform.zip \
         "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGET}.zip" \
    && unzip -o /tmp/terraform.zip -d /usr/local/bin && rm /tmp/terraform.zip \
    && curl $CURL_FLAGS -o /tmp/govc.tar.gz \
         "https://github.com/vmware/govmomi/releases/download/${GOVC_VERSION}/govc_Linux_${govc_arch}.tar.gz" \
    && tar -xzf /tmp/govc.tar.gz -C /usr/local/bin govc && rm /tmp/govc.tar.gz \
    && curl $CURL_FLAGS -o /usr/local/bin/sops \
         "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${TARGET}" \
    && chmod +x /usr/local/bin/sops \
    && curl $CURL_FLAGS -o /tmp/age.tar.gz \
         "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-${TARGET}.tar.gz" \
    && tar -xzf /tmp/age.tar.gz -C /tmp \
    && install -m 0755 "/tmp/age/age" "/tmp/age/age-keygen" /usr/local/bin/ \
    && rm -rf /tmp/age /tmp/age.tar.gz

# The node:22 image already ships a uid-1000 "node" user. Rename it to
# "vmpilot" (keeps uid 1000 = the repo owner on the deploy host).
RUN usermod -l vmpilot -d /home/vmpilot -m node \
    && mkdir -p /etc/sudoers.d \
    && echo 'vmpilot  ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/vmpilot \
    && echo 'Defaults env_keep += "SOPS_AGE_KEY_FILE"' >> /etc/sudoers.d/vmpilot \
    && mkdir -p /home/vmpilot/.govmomi/sessions && chown -R vmpilot:node /home/vmpilot/.govmomi

# The process is dropped to uid 1000 in docker-compose; the image default stays root
# so the pty can also be spawned for other uids if needed.
ENV NODE_ENV=production
WORKDIR /app
EXPOSE 3000
CMD ["node", "src/index.js"]