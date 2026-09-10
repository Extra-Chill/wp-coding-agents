#!/bin/bash
# Deterministic stat fixtures for portable file metadata helper tests.

stat_fixture_gnu() {
  [ "$1" = '-c' ] || return 1
  case "$2" in
    '%a') printf '%s\n' 640 ;;
    '%U') printf '%s\n' fixture-owner ;;
    '%u') printf '%s\n' 501 ;;
    '%G') printf '%s\n' fixture-group ;;
    *) return 1 ;;
  esac
}

stat_fixture_bsd() {
  [ "$1" = '-f' ] || return 1
  case "$2" in
    '%Lp') printf '%s\n' 640 ;;
    '%Su') printf '%s\n' fixture-owner ;;
    '%u') printf '%s\n' 501 ;;
    '%Sg') printf '%s\n' fixture-group ;;
    *) return 1 ;;
  esac
}
