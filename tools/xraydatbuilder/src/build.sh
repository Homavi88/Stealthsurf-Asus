#! /bin/sh

ARCHNAME=${1:-arm}

export GOOS=linux
export GOARCH=$ARCHNAME
export GOARM=5

go build -trimpath -ldflags "-s -w" -o ./../dist/xraydatbuilder .
