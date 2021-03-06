####################################################################################################################################
# DB VERSION MODULE
####################################################################################################################################
package pgBackRest::DbVersion;

use strict;
use warnings FATAL => qw(all);
use Carp qw(confess);

use Exporter qw(import);
    our @EXPORT =  qw();

use pgBackRest::Common::Log;

####################################################################################################################################
# PostgreSQL version numbers
####################################################################################################################################
use constant PG_VERSION_83                                          => '8.3';
    push @EXPORT, qw(PG_VERSION_83);
use constant PG_VERSION_84                                          => '8.4';
    push @EXPORT, qw(PG_VERSION_84);
use constant PG_VERSION_90                                          => '9.0';
    push @EXPORT, qw(PG_VERSION_90);
use constant PG_VERSION_91                                          => '9.1';
    push @EXPORT, qw(PG_VERSION_91);
use constant PG_VERSION_92                                          => '9.2';
    push @EXPORT, qw(PG_VERSION_92);
use constant PG_VERSION_93                                          => '9.3';
    push @EXPORT, qw(PG_VERSION_93);
use constant PG_VERSION_94                                          => '9.4';
    push @EXPORT, qw(PG_VERSION_94);
use constant PG_VERSION_95                                          => '9.5';
    push @EXPORT, qw(PG_VERSION_95);
use constant PG_VERSION_96                                          => '9.6';
    push @EXPORT, qw(PG_VERSION_96);

####################################################################################################################################
# versionSupport
#
# Returns an array of the supported Postgres versions.
####################################################################################################################################
sub versionSupport
{
    # Assign function parameters, defaults, and log debug info
    my ($strOperation) = logDebugParam(__PACKAGE__ . '->versionSupport');

    my @strySupportVersion = (PG_VERSION_83, PG_VERSION_84, PG_VERSION_90, PG_VERSION_91, PG_VERSION_92, PG_VERSION_93,
                              PG_VERSION_94, PG_VERSION_95, PG_VERSION_96);

    # Return from function and log return values if any
    return logDebugReturn
    (
        $strOperation,
        {name => 'strySupportVersion', value => \@strySupportVersion}
    );
}

push @EXPORT, qw(versionSupport);

1;
