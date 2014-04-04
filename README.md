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


Bulk Creation of Zimbra Accounts
--------------------------------
zimbra-bulk-create.pl will query an LDAP server for user attributes. 

The LDAP search amount can be filtered by the filter argument in the 
config file and also with the ldapfilter argument on the command line.

zimbra-build-create will print an zmprov output which can be inserted
to the Zimbra system with

    zmprov -f zimbra-bulk-create.txt

### Example

Example configuration file:

Content of ./etc/zimbra-bulk-create.yml

     LDAP:
  
       server:       ldap://ldap.example.com
       binduser:     cn=ldapsearchuser,dc=example,dc=com
       bindpassword: secret
       base:         dc=example,dc=com
       filter:       (&(objectClass=Users)_LDAPFILTER_)

       specialfields:
           username:   uid
           alias:      mail
           password:   plainpassword

       fields:
           gn:               givenname
           sn:               sn
           c:                c
           zimbraPrefLocale: lang

Run bulk creation script:

     ./bin/zimbra-bulk-create.pl \
       --defaultdomain=example.com \
       --defaultcosid=ABCD-EFG-1234 \
       --ldapfilter '(uid=rplessl)'

     ## Selected users: ##
       rplessl
     Do you want proceed? Then type here YES

Output will be:

     createAccount rplessl@example.com PASSWORD \
	   displayname "Roman Plessl" \
           zimbraPasswordMustChange FALSE \
	   zimbraPrefLocale de \
	   gn Roman \
	   sn Plessl \
	   c CH \
	   zimbraCOSid ABCD-EFG-1234
