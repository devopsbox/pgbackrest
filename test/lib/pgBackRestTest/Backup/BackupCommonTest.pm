####################################################################################################################################
# BackupCommonTest.pm - Common code for backup unit tests
####################################################################################################################################
package pgBackRestTest::Backup::BackupCommonTest;

####################################################################################################################################
# Perl includes
####################################################################################################################################
use strict;
use warnings FATAL => qw(all);
use Carp qw(confess);

use Exporter qw(import);
    our @EXPORT = qw();

use pgBackRest::Common::Log;
use pgBackRest::Config::Config;

use pgBackRestTest::Backup::Common::HostBackupTest;
use pgBackRestTest::Backup::Common::HostBaseTest;
use pgBackRestTest::Backup::Common::HostDbCommonTest;
use pgBackRestTest::Backup::Common::HostDbTest;
use pgBackRestTest::Backup::Common::HostDbSyntheticTest;
use pgBackRestTest::Common::HostGroupTest;
use pgBackRestTest::CommonTest;

####################################################################################################################################
# backupTestSetup
####################################################################################################################################
sub backupTestSetup
{
    my $bRemote = shift;
    my $bSynthetic = shift;
    my $oLogTest = shift;
    my $oConfigParam = shift;

    # Get host group
    my $oHostGroup = hostGroupGet();

    # Create the backup host
    my $oHostBackup = undef;

    if ($bRemote)
    {
        $oHostBackup = new pgBackRestTest::Backup::Common::HostBackupTest(
            {strDbMaster => HOST_DB_MASTER, bSynthetic => $bSynthetic, oLogTest => $bSynthetic ? $oLogTest : undef});
        $oHostGroup->hostAdd($oHostBackup);
    }

    # Create the db-master host
    my $oHostDbMaster = undef;

    if ($bSynthetic)
    {
        $oHostDbMaster = new pgBackRestTest::Backup::Common::HostDbSyntheticTest(
            {oHostBackup => $oHostBackup, oLogTest => $oLogTest});
    }
    else
    {
        $oHostDbMaster = new pgBackRestTest::Backup::Common::HostDbTest({oHostBackup => $oHostBackup});
    }

    $oHostGroup->hostAdd($oHostDbMaster);

    # Create the db-standby host
    my $oHostDbStandby = undef;

    if (defined($$oConfigParam{bStandby}) && $$oConfigParam{bStandby})
    {
        $oHostDbStandby = new pgBackRestTest::Backup::Common::HostDbTest(
            {bStandby => true, oHostBackup => $oHostBackup, oLogTest => $oLogTest});

        $oHostGroup->hostAdd($oHostDbStandby);
    }

    # Create the local file object
    my $oFile =
        new pgBackRest::File
        (
            $oHostDbMaster->stanza(),
            $oHostDbMaster->repoPath(),
            undef,
            new pgBackRest::Protocol::Common
            (
                OPTION_DEFAULT_BUFFER_SIZE,                 # Buffer size
                OPTION_DEFAULT_COMPRESS_LEVEL,              # Compress level
                OPTION_DEFAULT_COMPRESS_LEVEL_NETWORK,      # Compress network level
                HOST_PROTOCOL_TIMEOUT                       # Protocol timeout
            )
        );

    # Create db master config
    $oHostDbMaster->configCreate({
        bCompress => $$oConfigParam{bCompress},
        bHardlink => $bRemote ? undef : $$oConfigParam{bHardLink},
        bArchiveAsync => $$oConfigParam{bArchiveAsync}});

    # Create backup config if backup host exists
    if (defined($oHostBackup))
    {
        $oHostBackup->configCreate({
            bCompress => $$oConfigParam{bCompress},
            bHardlink => $$oConfigParam{bHardLink}});
    }
    # If backup host is not defined set it to db-master
    else
    {
        $oHostBackup = defined($oHostBackup) ? $oHostBackup : $oHostDbMaster;
    }

    # Create db-standby config
    if (defined($oHostDbStandby))
    {
        $oHostDbStandby->configCreate({
            bCompress => $$oConfigParam{bCompress},
            bHardlink => $bRemote ? undef : $$oConfigParam{bHardLink},
            bArchiveAsync => $$oConfigParam{bArchiveAsync}});
    }

    return $oHostDbMaster, $oHostDbStandby, $oHostBackup, $oFile;
}

push @EXPORT, qw(backupTestSetup);

1;
