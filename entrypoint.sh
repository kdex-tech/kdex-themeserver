#!/bin/bash

# if [ -n "${CORS_PROTOCOL}" ] && [ -n "${CORS_DOMAINS}" ]; then
# 	read -r -a cors_domains_array <<< "${CORS_DOMAINS}"
# 	for i in "${cors_domains_array[@]}"; do
# 		url="${CORS_PROTOCOL}://${i}"

# 		cat >> /etc/caddy.d/custom <<- EOF
# 		@origin-${i} header Origin ${url}
# 		header @origin-${i} Access-Control-Allow-Origin "${url}"
# 		EOF
# 	done
# fi

if [ -n "${ERROR_PAGE_404}" ]
then
	cat >> /etc/caddy.d/custom <<- EOF
	handle_errors {

		@404 expression {http.error.status_code} == 404
		handle @404 {
			redir * ${ERROR_PAGE_404} 301
		}

	}
	EOF
fi

caddy run --adapter caddyfile --config /etc/caddy/Caddyfile
