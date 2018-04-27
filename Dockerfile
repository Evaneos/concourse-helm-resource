FROM linkyard/docker-helm:2.9.1
LABEL maintainer "mario.siegenthaler@linkyard.ch"

RUN apk add --update --upgrade --no-cache jq bash nodejs curl yarn

ARG KUBERNETES_VERSION=1.10.4
RUN curl -L -o /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/v${KUBERNETES_VERSION}/bin/linux/amd64/kubectl; \
    chmod +x /usr/local/bin/kubectl

RUN apk add --no-cache python
RUN curl -sSL https://sdk.cloud.google.com | bash
RUN /root/google-cloud-sdk/install.sh --quiet --rc-path /root/.bashrc
RUN ln -s /root/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud

RUN yarn global add typescript

ADD wait-for-helm-deployment /opt/wait-for-helm-deployment
RUN cd /opt/wait-for-helm-deployment && \
    yarn

ADD assets /opt/resource
RUN chmod +x /opt/resource/*

RUN mkdir -p "$(helm home)/plugins"
RUN helm plugin install https://github.com/databus23/helm-diff

ENTRYPOINT [ "/bin/bash" ]
