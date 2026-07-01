ARG BUILD_ARCH=amd64
FROM ghcr.io/home-assistant/${BUILD_ARCH}-base:3.20

ARG TARGETARCH
ARG KOPIA_VERSION=latest

RUN set -eux; \
		apk add --no-cache bash jq curl tar ca-certificates; \
		if ! apk add --no-cache kopia; then \
			echo "Package 'kopia' is not available in Alpine repositories. Falling back to official GitHub binary."; \
			ARCH="${TARGETARCH:-$(uname -m)}"; \
			case "${ARCH}" in \
				amd64|x86_64) KOPIA_ARCH="x64" ;; \
				arm64|aarch64) KOPIA_ARCH="arm64" ;; \
				*) echo "Unsupported architecture for fallback install: ${ARCH}"; exit 1 ;; \
			esac; \
			if [ -z "${KOPIA_VERSION}" ] || [ "${KOPIA_VERSION}" = "latest" ]; then \
				KOPIA_VERSION="$(curl -fsSL https://api.github.com/repos/kopia/kopia/releases/latest | jq -r '.tag_name' | sed 's/^v//')"; \
			fi; \
			KOPIA_URL="https://github.com/kopia/kopia/releases/download/v${KOPIA_VERSION}/kopia-${KOPIA_VERSION}-linux-${KOPIA_ARCH}.tar.gz"; \
			curl -fL "${KOPIA_URL}" -o /tmp/kopia.tar.gz; \
			mkdir -p /tmp/kopia-extract; \
			tar -xzf /tmp/kopia.tar.gz -C /tmp/kopia-extract; \
			KOPIA_BIN="$(find /tmp/kopia-extract -type f -name kopia | head -n 1)"; \
			[ -n "${KOPIA_BIN}" ] || { echo "Kopia binary was not found in downloaded archive"; exit 1; }; \
			install -m 0755 "${KOPIA_BIN}" /usr/local/bin/kopia; \
			rm -f /tmp/kopia.tar.gz; \
			rm -rf /tmp/kopia-extract; \
		fi; \
		kopia --version

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
