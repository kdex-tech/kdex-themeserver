#!/bin/bash

// if DUMP_PUBLIC_RESOURCES is set, dump the public resources directory
if [ ! -z "${DUMP_PUBLIC_RESOURCES}" ]; then
    tree ${PUBLIC_RESOURCES_DIR:-/public}
fi

caddy run --adapter caddyfile --config /etc/caddy/Caddyfile