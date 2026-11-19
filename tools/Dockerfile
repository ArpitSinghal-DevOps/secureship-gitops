# Toolbox image: every CLI this project needs, so nothing is installed on the laptop.
FROM alpine:3.22
ARG UID=1000
ARG GID=1000
ARG COSIGN_VERSION=v3.1.4
RUN apk add --no-cache bash git openssh-client curl github-cli yq-go \
 && addgroup -g "$GID" tool && adduser -D -u "$UID" -G tool -h /home/tool tool \
 && cd /tmp \
 && curl -sSLO "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" \
 && curl -sSL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign_checksums.txt" \
      | grep " cosign-linux-amd64$" | sha256sum -c \
 && install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign && rm cosign-linux-amd64 \
 && apk add --no-cache docker-cli gcompat
ARG MINIKUBE_VERSION=v1.39.0
RUN cd /tmp \
 && curl -sSLo minikube "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-amd64" \
 && echo "$(curl -sSL https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-amd64.sha256 | cut -d' ' -f1)  minikube" | sha256sum -c \
 && install -m 0755 minikube /usr/local/bin/minikube && rm minikube
USER tool
# The repo is bind-mounted from the laptop; trust it inside the container.
RUN git config --global safe.directory '*' && mkdir -p /home/tool/.minikube
WORKDIR /home/tool
