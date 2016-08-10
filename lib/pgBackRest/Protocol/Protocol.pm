####################################################################################################################################
# PROTOCOL MODULE
####################################################################################################################################
package pgBackRest::Protocol::Protocol;

use strict;
use warnings FATAL => qw(all);
use Carp qw(confess);

# use Cwd qw(abs_path);
use Exporter qw(import);
    our @EXPORT = qw();
# use File::Basename qw(dirname basename);
# use Getopt::Long qw(GetOptions);
# use Storable qw(dclone);

# use pgBackRest::Common::Exception;
# use pgBackRest::Common::Ini;
use pgBackRest::Common::Log;
# use pgBackRest::Common::Wait;
use pgBackRest::Config::Config;
use pgBackRest::Protocol::Common;
use pgBackRest::Protocol::RemoteMaster;
# use pgBackRest::Version;

####################################################################################################################################
# Module variables
####################################################################################################################################
my $hProtocol = {};         # Global remote hash that is created on first request (NOT THREADSAFE!)

####################################################################################################################################
# isRepoLocal
#
# Is the backup/archive repository local?  This does not take into account the spool path.
####################################################################################################################################
sub isRepoLocal
{
    # Not valid for remote
    if (commandTest(CMD_REMOTE))
    {
        confess &log(ASSERT, 'isRepoLocal() not valid on remote');
    }

    return optionTest(OPTION_BACKUP_HOST) ? false : true;
}

push @EXPORT, qw(isRepoLocal);

####################################################################################################################################
# isDbLocal
#
# Is the database local?
####################################################################################################################################
sub isDbLocal
{
    # Not valid for remote
    if (commandTest(CMD_REMOTE))
    {
        confess &log(ASSERT, 'isDbLocal() not valid on remote');
    }

    return optionTest(OPTION_DB_HOST) ? false : true;
}

push @EXPORT, qw(isDbLocal);

####################################################################################################################################
# protocolGet
#
# Get the protocol object or create it if does not exist.  Shared protocol objects are used because they create an SSH connection
# to the remote host and the number of these connections should be minimized.  A protocol object can be shared within a single
# thread - for new threads clone() should be called on the shared protocol object.
####################################################################################################################################
sub protocolGet
{
    # Assign function parameters, defaults, and log debug info
    my
    (
        $strOperation,
        $strRemoteType,
        $oParam,
    ) =
        logDebugParam
        (
            __PACKAGE__ . '::protocolGet', \@_,
            {name => 'strRemoteType'},
            {name => 'oParam', required => false},
        );

    # Protocol object
    my $oProtocol;

    # If no remote requested or if the requested remote type is local then return a local protocol object
    my $strRemoteHost = $strRemoteType eq NONE ? undef : "${strRemoteType}-host";

    if ($strRemoteType eq NONE || !optionTest($strRemoteHost))
    {
        logDebugMisc($strOperation, 'create local protocol');

        $oProtocol = new pgBackRest::Protocol::Common
        (
            optionGet(OPTION_BUFFER_SIZE),
            commandTest(CMD_EXPIRE) ? OPTION_DEFAULT_COMPRESS_LEVEL : optionGet(OPTION_COMPRESS_LEVEL),
            commandTest(CMD_EXPIRE) ? OPTION_DEFAULT_COMPRESS_LEVEL_NETWORK : optionGet(OPTION_COMPRESS_LEVEL_NETWORK),
            optionGet(OPTION_PROTOCOL_TIMEOUT)
        );
    }
    # Else create the remote protocol
    else
    {
        my $bCache = defined($$oParam{bCache}) ? $$oParam{bCache} : true;

        # Set protocol to cached value
        $oProtocol =
            $bCache && defined($$hProtocol{$strRemoteType}) ? $$hProtocol{$strRemoteType} : undef;

        if ($bCache && $$hProtocol{$strRemoteType})
        {
            $oProtocol = $$hProtocol{$strRemoteType};
            logDebugMisc($strOperation, 'found cached protocol');
        }

        # If protocol was not returned from cache then create it
        if (!defined($oProtocol))
        {
            logDebugMisc($strOperation, 'create (' . ($bCache ? '' : 'un') . 'cached) remote protocol');

            # Return the remote when required
            my $strOptionCmd = OPTION_BACKUP_CMD;
            my $strOptionConfig = OPTION_BACKUP_CONFIG;
            my $strOptionHost = OPTION_BACKUP_HOST;
            my $strOptionUser = OPTION_BACKUP_USER;
            my $strOptionDbSocketPath = undef;

            if ($strRemoteType eq DB)
            {
                $strOptionCmd = OPTION_DB_CMD;
                $strOptionConfig = OPTION_DB_CONFIG;
                $strOptionHost = OPTION_DB_HOST;
                $strOptionUser = OPTION_DB_USER;

            }

            # Db socket is not valid in all contexts (restore, for instance)
            if (optionValid(OPTION_DB_SOCKET_PATH))
            {
                $strOptionDbSocketPath =
                    optionSource(OPTION_DB_SOCKET_PATH) eq SOURCE_DEFAULT ?
                        undef : optionGet(OPTION_DB_SOCKET_PATH);
            }

            $oProtocol = new pgBackRest::Protocol::RemoteMaster
            (
                $strRemoteType,
                commandWrite(
                    CMD_REMOTE, true, optionGet($strOptionCmd), undef,
                    {
                        &OPTION_COMMAND => {value => commandGet()},
                        &OPTION_PROCESS => {value => $$oParam{iProcessIdx}},
                        &OPTION_CONFIG => {
                            value => optionSource($strOptionConfig) eq SOURCE_DEFAULT ? undef : optionGet($strOptionConfig)},
                        &OPTION_TYPE => {value => $strRemoteType},
                        &OPTION_LOG_PATH => {},
                        &OPTION_LOCK_PATH => {},
                        &OPTION_DB_SOCKET_PATH => {value => $strOptionDbSocketPath},
                    }),
                optionGet(OPTION_BUFFER_SIZE),
                commandTest(CMD_EXPIRE) ? OPTION_DEFAULT_COMPRESS_LEVEL : optionGet(OPTION_COMPRESS_LEVEL),
                commandTest(CMD_EXPIRE) ? OPTION_DEFAULT_COMPRESS_LEVEL_NETWORK : optionGet(OPTION_COMPRESS_LEVEL_NETWORK),
                optionGet($strOptionHost),
                optionGet($strOptionUser),
                optionGet(OPTION_PROTOCOL_TIMEOUT)
            );

            # Cache the protocol
            if ($bCache)
            {
                $$hProtocol{$strRemoteType} = $oProtocol;
            }
        }
    }

    # Return from function and log return values if any
    return logDebugReturn
    (
        $strOperation,
        {name => 'oProtocol', value => $oProtocol, trace => true}
    );
}

push @EXPORT, qw(protocolGet);

####################################################################################################################################
# protocolDestroy
#
# Undefine the protocol if it is stored locally.
####################################################################################################################################
sub protocolDestroy
{
    # Assign function parameters, defaults, and log debug info
    my
    (
        $strOperation,
        $strRemoteType
    ) =
        logDebugParam
        (
            __PACKAGE__ . '::protocolDestroy', \@_,
            {name => 'strRemoteType', required => false}
        );

    my $iExitStatus = 0;

    if (defined($strRemoteType))
    {
        if (defined($$hProtocol{$strRemoteType}))
        {
            $iExitStatus = ($$hProtocol{$strRemoteType})->close();
            delete($$hProtocol{$strRemoteType});
        }
    }
    else
    {
        foreach my $strRemoteType (sort(keys(%{$hProtocol})))
        {
            if (defined($$hProtocol{$strRemoteType}))
            {
                logDebugMisc(
                    $strOperation, 'found cached protocol',
                    {name => 'strRemoteType', value => $strRemoteType});

                $iExitStatus = ($$hProtocol{$strRemoteType})->close();
                delete($$hProtocol{$strRemoteType});
            }
        }
    }

    # Return from function and log return values if any
    return logDebugReturn
    (
        $strOperation,
        {name => 'iExitStatus', value => $iExitStatus}
    );
}

push @EXPORT, qw(protocolDestroy);

1;
