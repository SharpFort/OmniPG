# ==============================================================================
# Policy Syncer Docker 构建
# 多阶段：Go Builder (golang:1.22-alpine) + 运行时 (alpine:3.19)
# 修复 N-3: COPY go.mod + go.sum 替代在构建阶段 go mod init
# ==============================================================================

FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /app

# 复制依赖描述文件（利用 Docker 缓存层，仅在这些文件改变时重新下载）
COPY go.mod go.sum ./
RUN go mod download

# 复制源码并编译为静态二进制
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags='-w -s -extldflags "-static"' \
    -o policy-syncer main.go

FROM alpine:3.19

RUN apk add --no-cache ca-certificates tzdata

COPY --from=builder /app/policy-syncer /usr/local/bin/policy-syncer

RUN addgroup -S syncer && adduser -S syncer -G syncer
USER syncer

EXPOSE 8080

ENTRYPOINT ["policy-syncer"]
