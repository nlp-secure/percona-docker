#!/bin/bash

mkdir -p /app/storage/app/public \
         /app/storage/framework/{cache,sessions,testing,views} \
         /app/storage/logs \
         /app/bootstrap/cache

chown -R nobody /app/bootstrap/cache /app/storage

gosu nobody php artisan migrate
gosu nobody php artisan migrate:fresh
gosu nobody php artisan serve --host=0.0.0.0 --port=80
