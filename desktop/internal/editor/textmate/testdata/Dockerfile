# syntax=docker/dockerfile:1
FROM golang:1.22 AS build
ARG VERSION=dev
ENV CGO_ENABLED=0 \
    GOOS=linux
WORKDIR /src
COPY --chown=app:app . .
RUN go build -ldflags "-X main.version=${VERSION}" -o /out/app ./cmd/app \
    && echo 'done'
FROM scratch
COPY --from=build /out/app /app
EXPOSE 8080/tcp
HEALTHCHECK CMD ["/app", "health"]
ENTRYPOINT ["/app"]
