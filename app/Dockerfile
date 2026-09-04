FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /counter .

FROM scratch
COPY --from=build /counter /counter
EXPOSE 8080
ENTRYPOINT ["/counter"]
