FROM alpine:3.16
LABEL maintainer="Carlos Nunez <dev@carlosnunez.me>"
LABEL repository="https://github.com/carlosonunez/terraform-docker"
ARG ARCH
ARG VERSION
ENV TERRAFORM_URL="https://releases.hashicorp.com/terraform/$VERSION/terraform_${VERSION}_linux_${ARCH}.zip"
RUN apk update
RUN apk add --no-cache curl unzip bash git

RUN curl -o /terraform.zip "$TERRAFORM_URL" && \
  unzip /terraform.zip && \
  chmod +x /terraform && \
  mv /terraform /usr/local/bin

ENTRYPOINT [ "terraform" ]
