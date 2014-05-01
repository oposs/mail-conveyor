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
    $ $EDITOR ./etc/mail-conveyor.yml


SSH Setup for cyrusmigration
----------------------------
The user configured in

    /opt/oss/mailconveyor/etc/mail-conveyor.yml

    Section ZimbraSSH

must be able to ssh to the Zimbra system with public key authentication
(without a keyring password).

Please set up such an environment which fits your system guidelines and
system adminstration steps.


Usage
-----
Migrate email accounts

    $ ./bin/mail-conveyor.pl \
        --oldserver oldserver.example.com \
        --newserver newserver.example.com \
        --popruxidb ./var/uidmatcher.db \
        --debug \
        --ldap \
        --ldapgroupfilter '(cn=MigrationGroup)' \
        --ldapuserfilter '(|(uid=user1)(uid=user2))' \
        --cyrusmigration \
        --domain example.com \
        --cyrusfiles /home/mailsync/cyrus_data

#Revert LDAP migration

The mail conveyor has a revert mode which resets the LDAP configration
to the old configuration. This allows in tests to rerun the migration.

    $ ./bin/mail-conveyor.pl \
        --oldserver oldserver.example.com \
        --newserver newserver.example.com \
        --debug \
        --ldap \
        --ldapgroupfilter '(cn=MigrationGroup)' \
        --ldapuserfilter '(|(uid=user1)(uid=user2))' \
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
        server:       ldap://ldap.example.com:389
        binduser:     cn=ldapsearchuser,dc=example,dc=com
        bindpassword: secret

        groupbase:    o=Providers,dc=example,dc=com
        groupfilter:  (&(objectClass=groupOfUniqueNames)_GROUPFILTER_)

        userbase:     cn=Users,dc=example,dc=com
        userfilter:   (&(objectClass=Users)_FROMGROUPFILTER__USERFILTER_)

        specialfields:
            username:   uid
            alias:      mail
            password:   plainpassword
            gn:         givenname
            sn:         sn

        copykeyvaluefields:
            gn:               givenname
            sn:               sn
            c:                c
            zimbraPrefLocale: lang

Run bulk creation script:

    ./bin/zimbra-bulk-create.pl \
        --defaultdomain   example.com \
        --defaultcosid    ABCD-EFG-1234 \
        --ldapgroupfilter '(cn=MigrationGroup)' \
        --ldapuserfilter  '(uid=rplessl)'

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
