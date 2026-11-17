# syntax=docker/dockerfile:1.19@sha256:b6afd42430b15f2d2a4c5a02b919e98a525b785b1aaff16747d2f623364e39b6
# Throwaway images for the pool probe: fount-broker's runner (a dev build, so it takes an
# unattested coordinator) and fount-supervisor with gVisor, both from one pinned fount-broker
# commit. The digests that get measured come from Build Image.
FROM golang:1.27.4-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS build
ARG BROKER_REV=396736a1dff20cf3b322ad40827ac68887d7ce67
ADD --keep-git-dir=false https://github.com/fount-labs/fount-broker.git#${BROKER_REV} /src
WORKDIR /src
ENV CGO_ENABLED=0 GOFLAGS=-trimpath GOTOOLCHAIN=local
RUN go build -tags dev -buildvcs=false -ldflags "-s -w -buildid=" -o /out/fount-broker ./cmd/fount-broker \
 && go build -buildvcs=false -ldflags "-s -w -buildid=" -o /out/fount-supervisor ./cmd/fount-supervisor

FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f AS gvisor
ARG GVISOR=20261109.0
ARG GVISOR_SHA512=1a6b8f74c37b4931ef473f67ec1f601690855bedc52ac709f2fac965c69677aa0426ef44598d8eee1aed72cfdb9df87a2a5f352cb3348880fc61a7732bc10f2a
RUN wget -q -O /gvisor.tar.bz2 "https://storage.googleapis.com/gvisor/releases/release/${GVISOR}/x86_64/gvisor.tar.bz2" \
 && echo "${GVISOR_SHA512}  /gvisor.tar.bz2" | sha512sum -c - \
 && mkdir /out && tar -xjf /gvisor.tar.bz2 -C /out runsc gvisor-bin \
 && /out/runsc --version | head -1

FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f AS broker
COPY --from=build /out/fount-broker /fount-broker
EXPOSE 7400
ENTRYPOINT ["/fount-broker"]

FROM alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f AS supervisor
COPY --from=gvisor /out/ /usr/local/bin/
COPY --from=build /out/fount-supervisor /fount-supervisor
ENTRYPOINT ["/fount-supervisor"]
