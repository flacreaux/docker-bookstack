#!/bin/bash
set -e

echoerr() { echo "$@" 1>&2; }

# Allow $XYZ_FILE to fill in the value of $XYZ from a file
# (helpful for Docker's secrets feature).
# Heavily cribbed from MariaDB.
# usage: file_env VAR [DEFAULT]
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
        echo >&2 "error: Both $var and $fileVar are set, but are exclusive."
        exit 1
    fi
    local val="$def"
    if [ "${!var:-}" ]; then
        val="${!var}"
    elif [ "${!fileVar:-}" ]; then
        val="$(< "${!fileVar}")"
    fi
    export "$var"="$val"
    unset "$fileVar"
}

# Initialize environment variables that might be stored in a file.
# $DB_HOST doesn't have a default value to properly trigger the
# "DB_HOST not defined" error.
file_env 'DB_HOST'
file_env 'DB_DATABASE' 'bookstack'
file_env 'DB_USERNAME' 'bookstack'
file_env 'DB_PASSWORD' 'password'

# Split out host and port from DB_HOST env variable
IFS=":" read -r DB_HOST_NAME DB_PORT <<< "$DB_HOST"
DB_PORT=${DB_PORT:-3306}

if [ ! -f ".env" ]; then
  if [[ "${DB_HOST}" ]]; then
  cat > ".env" <<EOF
      # Environment
      APP_ENV=production
      APP_DEBUG=${APP_DEBUG:-false}
      APP_KEY=${APP_KEY:-SomeRandomStringWith32Characters}

      # The below url has to be set if using social auth options
      # or if you are not using BookStack at the root path of your domain.
      APP_URL=${APP_URL:-null}

      # Database details
      DB_HOST=${DB_HOST}
      DB_DATABASE=${DB_DATABASE}
      DB_USERNAME=${DB_USERNAME}
      DB_PASSWORD=${DB_PASSWORD}

      # Cache and session
      CACHE_DRIVER=file
      SESSION_DRIVER=file
      # If using Memcached, comment the above and uncomment these
      #CACHE_DRIVER=memcached
      #SESSION_DRIVER=memcached
      QUEUE_DRIVER=sync

      # Memcached settings
      # If using a UNIX socket path for the host, set the port to 0
      # This follows the following format: HOST:PORT:WEIGHT
      # For multiple servers separate with a comma
      MEMCACHED_SERVERS=127.0.0.1:11211:100

      # Storage
      STORAGE_TYPE=${STORAGE_TYPE:-local}
      # Amazon S3 Config
      STORAGE_S3_KEY=${STORAGE_S3_KEY:-false}
      STORAGE_S3_SECRET=${STORAGE_S3_SECRET:-false}
      STORAGE_S3_REGION=${STORAGE_S3_REGION:-false}
      STORAGE_S3_BUCKET=${STORAGE_S3_BUCKET:-false}
      # Storage URL
      # Used to prefix image urls for when using custom domains/cdns
      STORAGE_URL=${STORAGE_URL:-false}

      # General auth
      AUTH_METHOD=${AUTH_METHOD:-standard}

      # Social Authentication information. Defaults as off.
      GITHUB_APP_ID=${GITHUB_APP_ID:-false}
      GITHUB_APP_SECRET=${GITHUB_APP_SECRET:-false}
      GOOGLE_APP_ID=${GOOGLE_APP_ID:-false}
      GOOGLE_APP_SECRET=${GOOGLE_APP_SECRET:-false}

      # External services such as Gravatar
      DISABLE_EXTERNAL_SERVICES=${DISABLE_EXTERNAL_SERVICES:-false}

      # LDAP Settings
      LDAP_SERVER=${LDAP_SERVER:-false}
      LDAP_BASE_DN=${LDAP_BASE_DN:-false}
      LDAP_DN=${LDAP_DN:-false}
      LDAP_PASS=${LDAP_PASS:-false}
      LDAP_USER_FILTER=${LDAP_USER_FILTER:-false}
      LDAP_VERSION=${LDAP_VERSION:-false}

      # Mail settings
      MAIL_DRIVER=${MAIL_DRIVER:-smtp}
      MAIL_HOST=${MAIL_HOST:-localhost}
      MAIL_PORT=${MAIL_PORT:-1025}
      MAIL_USERNAME=${MAIL_USERNAME:-null}
      MAIL_PASSWORD=${MAIL_PASSWORD:-null}
      MAIL_ENCRYPTION=${MAIL_ENCRYPTION:-null}
      # URL used for social login redirects, NO TRAILING SLASH
EOF
    else
        echo >&2 'error: One of either DB_HOST or DB_HOST_FILE must be defined.'
        exit 1
    fi
fi

echoerr "wait-for-db: waiting for ${DB_HOST_NAME}:${DB_PORT}"

timeout 15 bash <<EOT
while ! (echo > /dev/tcp/${DB_HOST_NAME}/${DB_PORT}) >/dev/null 2>&1;
    do sleep 1;
done;
EOT
RESULT=$?

if [ $RESULT -eq 0 ]; then
  # sleep another second for so that we don't get a "the database system is starting up" error
  sleep 1
  echoerr "wait-for-db: done"
else
  echoerr "wait-for-db: timeout out after 15 seconds waiting for ${DB_HOST_NAME}:${DB_PORT}"
fi

echo "Generating Key..."
php artisan key:generate --show

echo "Starting Migration..."
php artisan migrate --force

echo "Clearing caches..."
php artisan cache:clear
php artisan view:clear

trap "echo Catching SIGWINCH apache error and perventing it." SIGWINCH
exec apache2-foreground
