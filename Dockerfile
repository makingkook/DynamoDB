FROM alpine:3.24

RUN apk upgrade --no-cache

COPY book /app/book

RUN chmod +x /app/book

EXPOSE 8080

ENTRYPOINT ["/app/book"]
