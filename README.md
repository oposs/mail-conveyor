mail-conveyor
=============
Email synchronisation from one to another system using imapsync and popruxi

Use Case
--------
This tool migrate users from one email system to another and integrates
the toolboxes and scripts of [imapsync](https://github.com/imapsync/imapsync)
and [popruxi](https://github.com/oetiker/popruxi).

This script will get an amount of users from LDAP or from a flatfile and will
process the email migration for each user.


Installation
------------

First of all install popruxi

    $ cd /opt
    $ git clone https://github.com/oetiker/popruxi
    $ cd popruxi
    $ ./setup/build-perl-modules.sh
    $ cd ..

Afterwards install mail-conveyor

    $ cd /opt
    $ git clone https://github.com/rplessl/mail-conveyor
    $ cd mail-conveyor
    $ ./setup/build-perl-modules.sh
    $ ./setup/get-imapsync.sh

addapt the config file from

    $ cp ./etc/mail-conveyor.yml.dist ./etc/mail-conveyor.yml
    $ vim ./etc/mail-conveyor.yml

Usage
-----
Migrate email accounts

    $ ./bin/mail-conveyor.pl \
      --oldserver oldserver.example.com \
      --newserver newserver.example.com \
      --popruxidb ./var/uidmatcher.db \
      --debug \
      --ldap \
      --ldapfilter '(|(uid=user1)(uid=user2))' \
      --cyrusmigration \
      --domain example.com \      
      --cyrusfiles /home/mailsync/cyrus_data 

Revert LDAP fields

    $ ./bin/mail-conveyor.pl \
      --oldserver oldserver.example.com \
      --newserver newserver.example.com \
      --debug \
      --ldap \
      --ldapfilter '(|(uid=user1)(uid=user2))' \
      --resetmigrated
