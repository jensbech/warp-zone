# Global ARGs (declared before the first FROM) so they can be used in the FROMs below.
ARG BASE_IMAGE=ubuntu:24.04
# Only the jira build needs Go. Profiles without jira point this at their own base
# image instead, so nobody pays an 800 MB golang pull to touch an empty file.
ARG JIRA_BUILDER_IMAGE=ubuntu:24.04

FROM ${JIRA_BUILDER_IMAGE} AS jira-builder

ARG INCLUDE_JIRA=false

ENV CGO_ENABLED=0 GO111MODULE=on

RUN if [ "$INCLUDE_JIRA" = "true" ]; then \
      go install github.com/go-jira/jira/cmd/jira@v1.0.27; \
    else \
      mkdir -p /go/bin && touch /go/bin/jira; \
    fi

FROM ${BASE_IMAGE}

ARG DOCKER_VERSION=29.7.2
ARG DOCKER_BUILDX_VERSION=0.36.1
ARG DOCKER_COMPOSE_VERSION=5.5.0

ENV DEBIAN_FRONTEND=noninteractive \
    RUSTUP_HOME=/usr/local/rustup \
    PATH=/usr/local/go/bin:/usr/local/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN . /etc/os-release \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc \
 && chmod go+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
 && apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/docker.list -o Dir::Etc::sourceparts=/dev/null -o APT::Get::List-Cleanup=0 \
 && apt_sfx="1~${ID}.${VERSION_ID}~${VERSION_CODENAME}" \
 && docker_pkgs="containerd.io" \
 && if [ -n "$DOCKER_VERSION" ]; then docker_pkgs="$docker_pkgs docker-ce=5:${DOCKER_VERSION}-${apt_sfx} docker-ce-cli=5:${DOCKER_VERSION}-${apt_sfx}"; else docker_pkgs="$docker_pkgs docker-ce docker-ce-cli"; fi \
 && if [ -n "$DOCKER_BUILDX_VERSION" ]; then docker_pkgs="$docker_pkgs docker-buildx-plugin=${DOCKER_BUILDX_VERSION}-${apt_sfx}"; else docker_pkgs="$docker_pkgs docker-buildx-plugin"; fi \
 && if [ -n "$DOCKER_COMPOSE_VERSION" ]; then docker_pkgs="$docker_pkgs docker-compose-plugin=${DOCKER_COMPOSE_VERSION}-${apt_sfx}"; else docker_pkgs="$docker_pkgs docker-compose-plugin"; fi \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      bash bat build-essential bzip2 file fzf git iptables jq less lsb-release openssh-client procps ripgrep sudo tmux unzip vim wget xz-utils zip zsh zsh-autosuggestions zsh-syntax-highlighting \
      $docker_pkgs \
 && if apt-cache show eza >/dev/null 2>&1; then apt-get install -y --no-install-recommends eza; fi \
 && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git /opt/oh-my-zsh \
 && rm -rf /opt/oh-my-zsh/.git

ARG APP_USER=dev
ARG APP_UID=1001

RUN useradd -m -s /usr/bin/zsh -u "$APP_UID" "$APP_USER" \
 && usermod -aG sudo,docker "$APP_USER" \
 && install -d -o "$APP_USER" -g "$APP_USER" "/home/$APP_USER/.claude" "/home/$APP_USER/.config/opencode" "/home/$APP_USER/.github" "/home/$APP_USER/.jira.d" "/home/$APP_USER/.local/bin" "/home/$APP_USER/work" \
 && chown -R "$APP_USER:$APP_USER" "/home/$APP_USER" \
 && printf "%s ALL=(ALL) NOPASSWD:ALL\n" "$APP_USER" > "/etc/sudoers.d/$APP_USER" \
 && chmod 0440 "/etc/sudoers.d/$APP_USER" \
 && runuser -u "$APP_USER" -- env HOME="/home/$APP_USER" bash -c 'curl -fsSL https://claude.ai/install.sh | bash' \
 && test -x "/home/$APP_USER/.local/bin/claude"

COPY catalog.json install-tools.sh /usr/local/share/warp-zone/

ARG TOOLS=""
ARG LEGACY_INCLUDES=""
ARG TOOL_VERSIONS=""
ARG EXTRA_APT_PACKAGES=""

RUN bash /usr/local/share/warp-zone/install-tools.sh

COPY setup.sh /usr/local/share/warp-zone/setup.sh
RUN bash /usr/local/share/warp-zone/setup.sh

ARG INCLUDE_JIRA=false
COPY --from=jira-builder /go/bin/jira /usr/local/bin/jira
RUN if [ "$INCLUDE_JIRA" = "true" ]; then chmod +x /usr/local/bin/jira; else rm -f /usr/local/bin/jira; fi

COPY templates /opt/warp-zone/templates
COPY bootstrap-home /usr/local/bin/bootstrap-home
COPY warp-init /usr/local/bin/warp-init
RUN chmod +x /usr/local/bin/bootstrap-home /usr/local/bin/warp-init

ARG PROFILE_PROMPT=DEV
ENV APP_USER=${APP_USER} \
    APP_UID=${APP_UID} \
    APP_HOME=/home/${APP_USER} \
    PROFILE_PROMPT=${PROFILE_PROMPT} \
    PATH=/home/${APP_USER}/.local/bin:/home/${APP_USER}/.dotnet/tools:${PATH}

ENTRYPOINT ["/usr/local/bin/warp-init"]
