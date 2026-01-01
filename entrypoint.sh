#!/bin/bash

tree ${PUBLIC_RESOURCES_DIR:-/public}

caddy run --adapter caddyfile --config /etc/caddy/Caddyfile