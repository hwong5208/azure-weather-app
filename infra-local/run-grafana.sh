#!/bin/bash
# Install gettext-base for envsubst
apt-get update && apt-get install -y gettext-base

# Substitute environment variables in the datasource configuration
envsubst < /etc/grafana/provisioning/datasources/datasource.yml > /etc/grafana/provisioning/datasources/datasource.yml.tmp
mv /etc/grafana/provisioning/datasources/datasource.yml.tmp /etc/grafana/provisioning/datasources/datasource.yml

# Check configuration
cat /etc/grafana/provisioning/datasources/datasource.yml

# Start Grafana
exec /run.sh
