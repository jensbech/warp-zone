FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git iproute2 iptables just nodejs npm \
      openssh-client sudo docker.io \
 && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash tester \
 && usermod -aG docker tester \
 && echo 'tester ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tester
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
VOLUME /var/lib/docker
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
