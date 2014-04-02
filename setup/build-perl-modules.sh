#!/bin/bash

. `dirname $0`/sdbs.inc

# IMAPSYNC
for module in \
  Authen::NTLM \
  Data::Uniqid \
  Digest::HMAC_SHA1 \
  Digest::MD5 \
  File::Copy::Recursive \
  IO::Socket::IP \
  IO::Socket::SSL \
  Mail::IMAPClient \
  MIME::Base64 \
  Term::ReadKey \
  URI::Escape \
; do
  perlmodule $module
done

# mail-conveyor
for module in \
  Net::LDAP \
  YAML::XS \
  File::Temp \
; do
  perlmodule $module
done

        
