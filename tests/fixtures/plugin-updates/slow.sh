#!/bin/bash
set -eu
sleep "${PLUGIN_FIXTURE_SLEEP_SECONDS:-2}"
printf 'slow-fixture-complete\n'
