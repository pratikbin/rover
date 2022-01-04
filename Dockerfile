ARG NODE_VERSION=16
ARG GO_VERSION=1.17

FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-alpine as ui
WORKDIR /src
COPY ./ui/package*.json ./
RUN npm set progress=false && npm config set depth 0 && npm install
COPY ./ui/public ./public
COPY ./ui/src ./src
RUN npm run build

FROM --platform=$BUILDPLATFORM alpine:3.15 as terraform
SHELL ["/bin/sh", "-cex"]
ARG TF_VERSION="1.1.0"
ARG TARGETOS TARGETARCH
RUN wget -O tf.zip 'https://releases.hashicorp.com/terraform/'${TF_VERSION}'/terraform_'${TF_VERSION}'_'${TARGETOS}'_'${TARGETARCH}'.zip'; \
  unzip tf.zip

FROM --platform=$BUILDPLATFORM crazymax/goreleaser-xx:latest AS goreleaser-xx
FROM --platform=$BUILDPLATFORM pratikimprowise/upx:3.96 AS upx
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine AS base
COPY --from=goreleaser-xx / /
COPY --from=upx / /
ENV CGO_ENABLED=0
RUN apk --update add --no-cache git ca-certificates && \
  update-ca-certificates
WORKDIR /src

FROM base AS vendored
RUN --mount=type=bind,target=.,rw \
  --mount=type=cache,target=/go/pkg/mod \
  go mod tidy && go mod download

## Fat image
FROM vendored AS binary
COPY --from=ui /src/dist /src/ui/dist
COPY . .
ARG TARGETPLATFORM
RUN --mount=type=cache,target=/root/.cache \
  --mount=type=cache,target=/go/pkg/mod \
  goreleaser-xx --debug \
    --name="rover" \
    --main="." \
    --ldflags="-X main.version={{.Version}} -X main.commit={{.Commit}}" \
    --dist="/out" \
    --artifacts="bin" \
    --artifacts="archive" \
    --snapshot="no"

FROM scratch as fat
WORKDIR /tmp
WORKDIR /src
COPY --from=terraform /terraform           /usr/local/bin/terraform
COPY --from=base      /etc/ssl/certs/      /etc/ssl/certs/
COPY --from=binary    /usr/local/bin/rover /usr/local/bin/rover
ENTRYPOINT ["/usr/local/bin/rover"]
##

## Slim image
FROM vendored AS binary-slim
COPY --from=ui /src/dist /src/ui/dist
COPY . .
ARG TARGETPLATFORM
RUN --mount=type=cache,target=/root/.cache \
  --mount=type=cache,target=/go/pkg/mod \
  goreleaser-xx --debug \
    --name="rover-slim" \
    --flags="-trimpath" \
    --flags="-a" \
    --ldflags="-s -w -X main.version={{.Version}} -X main.commit={{.Commit}}" \
    --main="." \
    --dist="/out" \
    --artifacts="bin" \
    --artifacts="archive" \
    --snapshot="no" \
    --post-hooks="sh -c 'upx --ultra-brute --best /usr/local/bin/rover-slim || true'"

FROM scratch as slim
WORKDIR /tmp
WORKDIR /src
COPY --from=terraform   /terraform /usr/local/bin/terraform
COPY --from=base        /etc/ssl/certs/ /etc/ssl/certs/
COPY --from=binary-slim /usr/local/bin/rover-slim /usr/local/bin/rover
ENTRYPOINT ["/usr/local/bin/rover"]
##

## get binary out
### non slim binary
FROM scratch AS artifact
COPY --from=binary      /out /
###

### slim binary
FROM scratch AS artifact-slim
COPY --from=binary-slim /out /
###

### All binaries
FROM scratch AS artifact-all
COPY --from=binary      /out /
COPY --from=binary-slim /out /
###
##
