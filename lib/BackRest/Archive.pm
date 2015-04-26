####################################################################################################################################
# ARCHIVE MODULE
####################################################################################################################################
package BackRest::Archive;

use strict;
use warnings FATAL => qw(all);
use Carp qw(confess);

use File::Basename qw(dirname basename);
use Fcntl qw(SEEK_CUR O_RDONLY O_WRONLY O_CREAT O_EXCL);
use Exporter qw(import);
use POSIX qw(setsid);

use lib dirname($0);
use BackRest::Utility;
use BackRest::Exception;
use BackRest::Config;
use BackRest::Lock;
use BackRest::File;
use BackRest::Remote;

####################################################################################################################################
# Operation constants
####################################################################################################################################
use constant
{
    OP_ARCHIVE_PUSH_CHECK => 'Archive->pushCheck'
};

our @EXPORT = qw(OP_ARCHIVE_PUSH_CHECK);

####################################################################################################################################
# File constants
####################################################################################################################################
use constant
{
    ARCHIVE_INFO_FILE => 'archive.info'
};

push @EXPORT, qw(ARCHIVE_INFO_FILE);

####################################################################################################################################
# constructor
####################################################################################################################################
sub new
{
    my $class = shift;          # Class name

    # Create the class hash
    my $self = {};
    bless $self, $class;

    return $self;
}

####################################################################################################################################
# process
#
# Process archive commands.
####################################################################################################################################
sub process
{
    my $self = shift;

    # Process push
    if (operationTest(OP_ARCHIVE_PUSH))
    {
        return $self->pushProcess();
    }

    # Process get
    if (operationTest(OP_ARCHIVE_GET))
    {
        return $self->getProcess();
    }

    # Error if any other operation is found
    confess &log(ASSERT, "Archive->process() called with invalid operation: " . operationGet());
}

####################################################################################################################################
# getProcess
####################################################################################################################################
sub getProcess
{
    my $self = shift;

    # Make sure the archive file is defined
    my $strSourceArchive = $ARGV[1];

    if (!defined($ARGV[1]))
    {
        confess &log(ERROR, 'WAL segment not provided', ERROR_PARAM_REQUIRED);
    }

    # Make sure the destination file is defined
    my $strDestinationFile = $ARGV[2];

    if (!defined($strDestinationFile))
    {
        confess &log(ERROR, 'WAL segment destination not provided', ERROR_PARAM_REQUIRED);
    }

    # Info for the Postgres log
    &log(INFO, 'getting WAL segment ' . $ARGV[1]);

    # Get the async flag and start the timer
    my $bArchiveAsync = optionGet(OPTION_ARCHIVE_ASYNC) && $strSourceArchive =~ /^[0-F]{24}$/;
    my $oWaitGet = waitInit($bArchiveAsync ? 5 : undef);
    my $iResult = 1;
    my $bArchiveAsyncRunning = false;

    # Get the WAL segment
    do
    {
        # If async then fork the async process
        if ($bArchiveAsync && !$bArchiveAsyncRunning && lockAcquire(OP_ARCHIVE_GET))
        {
            my $pId;

            if ($pId = fork())
            {
                $bArchiveAsyncRunning = true;
                log_file_set(optionGet(OPTION_REPO_PATH) . '/log/' . optionGet(OPTION_STANZA) . '-archive');
            }
            elsif (defined($pId))
            {
                # Close file handles and reopen to /dev/null
                close STDIN;
                close STDOUT;
                close STDERR;

                open STDIN,  '<', '/dev/null' or die $!;
                open STDOUT, '>', '/dev/null' or die $!;
                open STDERR, '>', '/dev/null' or die $!;

                # Create a new session for this process
                setsid()
                    or confess &log(ERROR, "async process cannot start new session: $!");

                log_file_set(optionGet(OPTION_REPO_PATH) . '/log/' . optionGet(OPTION_STANZA) . '-archive-async');

                my $oWaitAsync = waitInit(30);
                my $iFileFetched;
                my $strLastFetchedArchive;

                do
                {
                    ($iFileFetched, $strLastFetchedArchive) = $self->getAsync($strSourceArchive, $strLastFetchedArchive);

                    if ($iFileFetched > 0)
                    {
                        &log(DEBUG, "WAIT RESET");
                        waitReset();
                    }

                    &log(DEBUG, 'async waiting');
                }
                while (waitMore($oWaitAsync));

                return 0;
            }
            else
            {
                &log(ERROR, 'unable to fork async process - switching async mode off');
                $bArchiveAsync = false;
            }
        }

        &log(DEBUG, "fetching $ARGV[1]");
        $iResult = $self->getOne($ARGV[1], $ARGV[2], $bArchiveAsync, false);
    }
    while ($iResult != 0 && waitMore($oWaitGet));

    return $iResult;
}

####################################################################################################################################
# getOne
####################################################################################################################################
sub getOne
{
    my $self = shift;
    my $strSourceArchive = shift;
    my $strDestinationFile = shift;
    my $bArchiveAsync = shift;
    my $bDestinationPathCreate = shift;

    # Create the file object
    my $oFile = new BackRest::File
    (
        optionGet(OPTION_STANZA),
        optionRemoteTypeTest(BACKUP) && !$bArchiveAsync ? optionGet(OPTION_REPO_REMOTE_PATH) : optionGet(OPTION_REPO_PATH),
        $bArchiveAsync ? NONE : optionRemoteType(),
        optionRemote($bArchiveAsync)
    );

    # Switch to a remote file object if needed
    if (optionRemoteTest())
    {
    }

    # If the destination file path is not absolute then it is relative to the db data path
    if (index($strDestinationFile, '/',) != 0)
    {
        if (!optionTest(OPTION_DB_PATH))
        {
            confess &log(ERROR, 'database path must be set if relative xlog paths are used');
        }

        $strDestinationFile = optionGet(OPTION_DB_PATH) . "/${strDestinationFile}";
    }

    # Get the wal segment filename
    my $strArchiveFile = $self->walFind($oFile, $bArchiveAsync ? PATH_BACKUP_ARCHIVE_IN : PATH_BACKUP_ARCHIVE,
                                        $strSourceArchive);

    # If there are no matching archive files then there are two possibilities:
    # 1) The end of the archive stream has been reached, this is normal and a 1 will be returned
    # 2) There is a hole in the archive stream and a hard error should be returned.  However, holes are possible due to
    #    async archiving and threading - so when to report a hole?  Since a hard error will cause PG to terminate, for now
    #    treat as case #1.
    if (!defined($strArchiveFile))
    {
        &log(INFO, "${strSourceArchive} was not found in the archive repository");

        return 1;
    }

    &log(DEBUG, "archive_get: cp ${strArchiveFile} ${strDestinationFile}");

    # Determine if the source file is already compressed
    my $bSourceCompressed = $strArchiveFile =~ "^.*\.$oFile->{strCompressExtension}\$" ? true : false;

    # Copy the archive file to the requested location
    $oFile->copy($bArchiveAsync ? PATH_BACKUP_ARCHIVE_IN : PATH_BACKUP_ARCHIVE, $strArchiveFile,    # Source file
                 PATH_DB_ABSOLUTE, $strDestinationFile,     # Destination file
                 $bSourceCompressed,                        # Source compression based on detection
                 false,                                     # Destination is not compressed
                 undef, undef, undef,
                 $bDestinationPathCreate);                  # Create destination path

    # If async then remove the copied file
    if ($bArchiveAsync)
    {
        $oFile->remove(PATH_BACKUP_ARCHIVE_IN, $strArchiveFile);
    }

    return 0;
}

####################################################################################################################################
# getAsync
####################################################################################################################################
sub getAsync
{
    my $self = shift;
    my $strRequestedArchive = shift;
    my $strLastFetchedArchive = shift;

    &log(DEBUG, "Archive->asyncGet: last requested = ${strRequestedArchive}, " .
                "last fetched = " . (defined($strLastFetchedArchive) ? $strLastFetchedArchive : 'none'));

    # Create the file object to get the local archive path
    my $oFile = new BackRest::File
    (
        optionGet(OPTION_STANZA),
        optionGet(OPTION_REPO_PATH),
        NONE,
        optionRemote(true)
    );

    my $strArchivePath = $oFile->path_get(PATH_BACKUP_ARCHIVE_IN);

    # Create the file object used to retrieve
    if (optionRemoteTest())
    {
        $oFile = new BackRest::File
        (
            optionGet(OPTION_STANZA),
            optionGet(OPTION_REPO_REMOTE_PATH),
            optionRemoteType(),
            optionRemote()
        );
    }

    # Get all files already in the in path
    my @stryWalFileName = $oFile->list(PATH_BACKUP_ARCHIVE_IN, undef, undef, undef, true);
    my $iFileExists = 0;
    my $strLastArchive;

    &log(DEBUG, "GOT HERE " . @stryWalFileName);

    foreach my $strFile (@stryWalFileName)
    {
        if ($strFile =~ "^[0-F]{24}-[0-f]{40}\$")
        {
            if ($strFile lt $strRequestedArchive)
            {
                &log(INFO, "removed old archive '${strFile}'");
            }
            else
            {
                if (!defined($strLastFetchedArchive) || $strLastFetchedArchive lt $strFile)
                {
                    $strLastFetchedArchive = substr($strFile, 0, 24);
                }

                $iFileExists++;
            }
        }
        else
        {
            &log(WARN, "invalid file '${strFile}' found in archive in path");
        }
    }

#    &log(DEBUG, "Archive->asyncGet: " . ($iFileExists > 0 ? "last found locally ${strLastArchive}" : "none found locally"));

    # If the number of existing files is lower than the threshold then fetch more
    my $iFileMore = 0;
    my $strNextArchive = defined($strLastFetchedArchive) ? $self->walNext($strLastFetchedArchive) : $strRequestedArchive;

    if ($iFileExists <= 32)
    {
        my $strNextArchiveFile = $self->walFind($oFile, PATH_BACKUP_ARCHIVE, $strNextArchive);

        while ($iFileExists < 3 && defined($strNextArchiveFile) &&
               $self->getOne($strNextArchive, "${strArchivePath}/$strNextArchiveFile", false, true) == 0)
        {
            $iFileMore++;
            $iFileExists++;
            $strLastFetchedArchive = $strNextArchive;
            $strNextArchive = $self->walNext($strNextArchive);
            $strNextArchiveFile = $self->walFind($oFile, PATH_BACKUP_ARCHIVE, $strNextArchive);
        }
    }

    &log(DEBUG, "Archive->asyncGet: " . ($iFileMore > 0 ? "stopped at ${strLastFetchedArchive}" : "nothing fetched"));

    return $iFileMore, $strLastFetchedArchive;
}

####################################################################################################################################
# pushProcess
####################################################################################################################################
sub pushProcess
{
    my $self = shift;

    # Make sure the archive push operation happens on the db side
    if (optionRemoteTypeTest(DB))
    {
        confess &log(ERROR, OP_ARCHIVE_PUSH . ' operation must run on the db host');
    }

    # Load the archive object
    use BackRest::Archive;

    # If an archive section has been defined, use that instead of the backup section when operation is OP_ARCHIVE_PUSH
    my $bArchiveAsync = optionGet(OPTION_ARCHIVE_ASYNC);
    my $strArchivePath = optionGet(OPTION_REPO_PATH);

    # If logging locally then create the stop archiving file name
    my $strStopFile;

    if ($bArchiveAsync)
    {
        $strStopFile = "${strArchivePath}/lock/" . optionGet(OPTION_STANZA) . "-archive.stop";
    }

    # If an archive file is defined, then push it
    if (defined($ARGV[1]))
    {
        # If the stop file exists then discard the archive log
        if ($bArchiveAsync)
        {
            if (-e $strStopFile)
            {
                &log(ERROR, "archive stop file (${strStopFile}) exists , discarding " . basename($ARGV[1]));
                remote_exit(0);
            }
        }

        &log(INFO, 'pushing WAL segment ' . $ARGV[1] . ($bArchiveAsync ? ' asynchronously' : ''));

        $self->pushOne($ARGV[1], $bArchiveAsync);

        # Exit if we are not archiving async
        if (!$bArchiveAsync)
        {
            return 0;
        }

        # Fork and exit the parent process so the async process can continue
        if (!optionTest(OPTION_TEST_NO_FORK) || !optionGet(OPTION_TEST_NO_FORK))
        {
            if (fork())
            {
                return 0;
            }
        }
        # Else the no-fork flag has been specified for testing
        else
        {
            &log(INFO, 'No fork on archive local for TESTING');
        }

        # Start the async archive push
        &log(INFO, 'starting async archive-push');
    }

    # Create a lock file to make sure async archive-push does not run more than once
    lockAcquire(operationGet());

    # Open the log file
    log_file_set(optionGet(OPTION_REPO_PATH) . '/log/' . optionGet(OPTION_STANZA) . '-archive-async');

    # Build the basic command string that will be used to modify the command during processing
    my $strCommand = $^X . ' ' . $0 . " --stanza=" . optionGet(OPTION_STANZA);

    # Call the pushAsync function and continue to loop as long as there are files to process
    my $iLogTotal;

    while (!defined($iLogTotal) || $iLogTotal > 0)
    {
        $iLogTotal = $self->pushAsync($strArchivePath . "/archive/" . optionGet(OPTION_STANZA) . "/out", $strStopFile);

        if ($iLogTotal > 0)
        {
            &log(DEBUG, "${iLogTotal} WAL segments were transferred, calling Archive->pushAsync() again");
        }
        else
        {
            &log(DEBUG, 'no more WAL segments to transfer - exiting');
        }
    }

    lockRelease();
    return 0;
}

####################################################################################################################################
# pushOne
####################################################################################################################################
sub pushOne
{
    my $self = shift;
    my $strSourceFile = shift;
    my $bAsync = shift;

    # Create the file object
    my $oFile = new BackRest::File
    (
        optionGet(OPTION_STANZA),
        $bAsync || optionRemoteTypeTest(NONE) ? optionGet(OPTION_REPO_PATH) : optionGet(OPTION_REPO_REMOTE_PATH),
        $bAsync ? NONE : optionRemoteType(),
        optionRemote($bAsync)
    );

    # If the source file path is not absolute then it is relative to the data path
    if (index($strSourceFile, '/',) != 0)
    {
        if (!optionTest(OPTION_DB_PATH))
        {
            confess &log(ERROR, 'database path must be set if relative xlog paths are used');
        }

        $strSourceFile = optionGet(OPTION_DB_PATH) . "/${strSourceFile}";
    }

    # Get the destination file
    my $strDestinationFile = basename($strSourceFile);

    # Get the compress flag
    my $bCompress = $bAsync ? false : optionGet(OPTION_COMPRESS);

    # Determine if this is an archive file (don't do compression or checksum on .backup, .history, etc.)
    my $bArchiveFile = basename($strSourceFile) =~ /^[0-F]{24}$/ ? true : false;

    # Check that there are no issues with pushing this WAL segment
    if ($bArchiveFile)
    {
        my ($strDbVersion, $ullDbSysId) = $self->walInfo($strSourceFile);
        $self->pushCheck($oFile, substr(basename($strSourceFile), 0, 24), $strDbVersion, $ullDbSysId);
    }

    # Append compression extension
    if ($bArchiveFile && $bCompress)
    {
        $strDestinationFile .= '.' . $oFile->{strCompressExtension};
    }

    # Copy the WAL segment
    $oFile->copy(PATH_DB_ABSOLUTE, $strSourceFile,                          # Source type/file
                 $bAsync ? PATH_BACKUP_ARCHIVE_OUT : PATH_BACKUP_ARCHIVE,   # Destination type
                 $strDestinationFile,                                       # Destination file
                 false,                                                     # Source is not compressed
                 $bArchiveFile && $bCompress,                               # Destination compress is configurable
                 undef, undef, undef,                                       # Unused params
                 true,                                                      # Create path if it does not exist
                 undef, undef,                                              # User and group
                 $bArchiveFile);                                            # Append checksum if archive file
}

####################################################################################################################################
# pushAsync
####################################################################################################################################
sub pushAsync
{
    my $self = shift;
    my $strArchivePath = shift;
    my $strStopFile = shift;

    # Create the file object
    my $oFile = new BackRest::File
    (
        optionGet(OPTION_STANZA),
        optionRemoteTypeTest(NONE) ? optionGet(OPTION_REPO_PATH) : optionGet(OPTION_REPO_REMOTE_PATH),
        optionRemoteType(),
        optionRemote()
    );

    # Load the archive manifest - all the files that need to be pushed
    my %oManifestHash;
    $oFile->manifest(PATH_DB_ABSOLUTE, $strArchivePath, \%oManifestHash);

    # Get all the files to be transferred and calculate the total size
    my @stryFile;
    my $lFileSize = 0;
    my $lFileTotal = 0;

    foreach my $strFile (sort(keys $oManifestHash{name}))
    {
        if ($strFile =~ "^[0-F]{24}(-[0-f]{40})(\\.$oFile->{strCompressExtension}){0,1}\$" ||
            $strFile =~ /^[0-F]{8}\.history$/ || $strFile =~ /^[0-F]{24}\.[0-F]{8}\.backup$/)
        {
            push(@stryFile, $strFile);

            $lFileSize += $oManifestHash{name}{"${strFile}"}{size};
            $lFileTotal++;
        }
    }

    if (optionTest(OPTION_ARCHIVE_MAX_MB))
    {
        my $iArchiveMaxMB = optionGet(OPTION_ARCHIVE_MAX_MB);

        if ($iArchiveMaxMB < int($lFileSize / 1024 / 1024))
        {
            &log(ERROR, "local archive store has exceeded limit of ${iArchiveMaxMB}MB, archive logs will be discarded");

            my $hStopFile;
            open($hStopFile, '>', $strStopFile) or confess &log(ERROR, "unable to create stop file file ${strStopFile}");
            close($hStopFile);
        }
    }

    if ($lFileTotal == 0)
    {
        &log(DEBUG, 'no archive logs to be copied to backup');

        return 0;
    }

    # Modify process name to indicate async archiving
    $0 = $^X . ' ' . $0 . " --stanza=" . optionGet(OPTION_STANZA) .
         "archive-push-async " . $stryFile[0] . '-' . $stryFile[scalar @stryFile - 1];

    # Output files to be moved to backup
    &log(INFO, "archive to be copied to backup total ${lFileTotal}, size " . file_size_format($lFileSize));

    # Transfer each file
    foreach my $strFile (sort @stryFile)
    {
        # Construct the archive filename to backup
        my $strArchiveFile = "${strArchivePath}/${strFile}";

        # Determine if the source file is already compressed
        my $bSourceCompressed = $strArchiveFile =~ "^.*\.$oFile->{strCompressExtension}\$" ? true : false;

        # Determine if this is an archive file (don't want to do compression or checksum on .backup files)
        my $bArchiveFile = basename($strFile) =~
            "^[0-F]{24}(-[0-f]+){0,1}(\\.$oFile->{strCompressExtension}){0,1}\$" ? true : false;

        # Figure out whether the compression extension needs to be added or removed
        my $bDestinationCompress = $bArchiveFile && optionGet(OPTION_COMPRESS);
        my $strDestinationFile = basename($strFile);

        if (!$bSourceCompressed && $bDestinationCompress)
        {
            $strDestinationFile .= ".$oFile->{strCompressExtension}";
        }
        elsif ($bSourceCompressed && !$bDestinationCompress)
        {
            $strDestinationFile = substr($strDestinationFile, 0, length($strDestinationFile) - 3);
        }

        &log(DEBUG, "archive ${strFile}, is WAL ${bArchiveFile}, source_compressed = ${bSourceCompressed}, " .
                    "destination_compress ${bDestinationCompress}, default_compress = " . optionGet(OPTION_COMPRESS));

        # Check that there are no issues with pushing this WAL segment
        if ($bArchiveFile)
        {
            my ($strDbVersion, $ullDbSysId) = $self->walInfo($strArchiveFile);
            $self->pushCheck($oFile, substr(basename($strArchiveFile), 0, 24), $strDbVersion, $ullDbSysId);
        }

        # Copy the archive file
        $oFile->copy(PATH_DB_ABSOLUTE, $strArchiveFile,         # Source file
                     PATH_BACKUP_ARCHIVE, $strDestinationFile,  # Destination file
                     $bSourceCompressed,                        # Source is not compressed
                     $bDestinationCompress,                     # Destination compress is configurable
                     undef, undef, undef,                       # Unused params
                     true);                                     # Create path if it does not exist

        #  Remove the source archive file
        unlink($strArchiveFile)
            or confess &log(ERROR, "copied ${strArchiveFile} to archive successfully but unable to remove it locally.  " .
                                   'This file will need to be cleaned up manually.  If the problem persists, check if ' .
                                   OP_ARCHIVE_PUSH . ' is being run with different permissions in different contexts.');
    }

    # Return number of files indicating that processing should continue
    return $lFileTotal;
}

####################################################################################################################################
# pushCheck
####################################################################################################################################
sub pushCheck
{
    my $self = shift;
    my $oFile = shift;
    my $strWalSegment = shift;
    my $strDbVersion = shift;
    my $ullDbSysId = shift;

    # Set operation and debug strings
    my $strOperation = OP_ARCHIVE_PUSH_CHECK;
    &log(DEBUG, "${strOperation}: " . PATH_BACKUP_ARCHIVE . ":${strWalSegment}");

    if ($oFile->is_remote(PATH_BACKUP_ARCHIVE))
    {
        # Build param hash
        my %oParamHash;

        $oParamHash{'wal-segment'} = $strWalSegment;
        $oParamHash{'db-version'} = $strDbVersion;
        $oParamHash{'db-sys-id'} = $ullDbSysId;

        # Output remote trace info
        &log(TRACE, "${strOperation}: remote (" . $oFile->{oRemote}->command_param_string(\%oParamHash) . ')');

        # Execute the command
        $oFile->{oRemote}->command_execute($strOperation, \%oParamHash);
    }
    else
    {
        # Create the archive path if it does not exist
        if (!$oFile->exists(PATH_BACKUP_ARCHIVE))
        {
            $oFile->path_create(PATH_BACKUP_ARCHIVE);
        }

        # If the info file exists check db version and system-id
        my %oDbConfig;

        if ($oFile->exists(PATH_BACKUP_ARCHIVE, ARCHIVE_INFO_FILE))
        {
            ini_load($oFile->path_get(PATH_BACKUP_ARCHIVE, ARCHIVE_INFO_FILE), \%oDbConfig);

            if ($oDbConfig{database}{'version'} ne $strDbVersion)
            {
                confess &log(ERROR, "WAL segment version ${strDbVersion} " .
                             "does not match archive version $oDbConfig{database}{'version'}", ERROR_ARCHIVE_MISMATCH);
            }

            if ($oDbConfig{database}{'system-id'} ne $ullDbSysId)
            {
                confess &log(ERROR, "WAL segment system-id ${ullDbSysId} " .
                             "does not match archive system-id $oDbConfig{database}{'system-id'}", ERROR_ARCHIVE_MISMATCH);
            }
        }
        # Else create the info file from the current WAL segment
        else
        {
            $oDbConfig{database}{'system-id'} = $ullDbSysId;
            $oDbConfig{database}{'version'} = $strDbVersion;
            ini_save($oFile->path_get(PATH_BACKUP_ARCHIVE, ARCHIVE_INFO_FILE), \%oDbConfig);
        }

        # Check if the WAL segment already exists in the archive
        if (defined($self->walFind($oFile, PATH_BACKUP_ARCHIVE, $strWalSegment)))
        {
            confess &log(ERROR, "WAL segment ${strWalSegment} already exists in the archive", ERROR_ARCHIVE_DUPLICATE);
        }
    }
}

####################################################################################################################################
# walFind
#
# Returns the filename in the archive of a WAL segment.  Optionally, a wait time can be specified.  In this case an error will be
# thrown when the WAL segment is not found.
####################################################################################################################################
sub walFind
{
    my $self = shift;
    my $oFile = shift;
    my $strPathType = shift;
    my $strWalSegment = shift;
    my $iWaitSeconds = shift;

    # Record the start time
    my $oWait = waitInit($iWaitSeconds);

    # Determine the path where the requested WAL segment is located
    my $strArchivePath = dirname($oFile->path_get($strPathType, $strWalSegment));

    do
    {
        # Get the name of the requested WAL segment (may have hash info and compression extension)
        my @stryWalFileName = $oFile->list(PATH_BACKUP_ABSOLUTE, $strArchivePath,
            "^${strWalSegment}(-[0-f]+){0,1}(\\.$oFile->{strCompressExtension}){0,1}\$", undef, true);

        # If there is only one result then return it
        if (@stryWalFileName == 1)
        {
            return $stryWalFileName[0];
        }

        # If there is more than one matching archive file then there is a serious issue - likely a bug in the archiver
        if (@stryWalFileName > 1)
        {
            confess &log(ASSERT, @stryWalFileName . " duplicate files found for ${strWalSegment}", ERROR_ARCHIVE_DUPLICATE);
        }
    }
    while (waitMore($oWait));

    # If waiting and no WAL segment was found then throw an error
    if (defined($iWaitSeconds))
    {
        confess &log(ERROR, "could not find WAL segment ${strWalSegment} after " . waitInterval($oWait)  . ' second(s)');
    }

    return undef;
}

####################################################################################################################################
# walInfo
#
# Retrieve information such as db version and system identifier from a WAL segment.
####################################################################################################################################
sub walInfo
{
    my $self = shift;
    my $strWalFile = shift;

    # Set operation and debug strings
    my $strOperation = 'Archive->walInfo';
    &log(TRACE, "${strOperation}: " . PATH_ABSOLUTE . ":${strWalFile}");

    # Open the WAL segment
    my $hFile;
    my $tBlock;

    sysopen($hFile, $strWalFile, O_RDONLY)
        or confess &log(ERROR, "unable to open ${strWalFile}", ERROR_FILE_OPEN);

    # Read magic
    sysread($hFile, $tBlock, 2) == 2
        or confess &log(ERROR, "unable to read xlog magic");

    my $iMagic = unpack('S', $tBlock);

    # Make sure the WAL magic is supported
    my $strDbVersion;
    my $iSysIdOffset;

    if ($iMagic == hex('0xD07E'))
    {
        $strDbVersion = '9.4';
        $iSysIdOffset = 20;
    }
    elsif ($iMagic == hex('0xD075'))
    {
        $strDbVersion = '9.3';
        $iSysIdOffset = 20;
    }
    elsif ($iMagic == hex('0xD071'))
    {
        $strDbVersion = '9.2';
        $iSysIdOffset = 12;
    }
    elsif ($iMagic == hex('0xD066'))
    {
        $strDbVersion = '9.1';
        $iSysIdOffset = 12;
    }
    elsif ($iMagic == hex('0xD064'))
    {
        $strDbVersion = '9.0';
        $iSysIdOffset = 12;
    }
    elsif ($iMagic == hex('0xD063'))
    {
        $strDbVersion = '8.4';
        $iSysIdOffset = 12;
    }
    elsif ($iMagic == hex('0xD062'))
    {
        $strDbVersion = '8.3';
        $iSysIdOffset = 12;
    }
    # elsif ($iMagic == hex('0xD05E'))
    # {
    #     $strDbVersion = '8.2';
    #     $iSysIdOffset = 12;
    # }
    # elsif ($iMagic == hex('0xD05D'))
    # {
    #     $strDbVersion = '8.1';
    #     $iSysIdOffset = 12;
    # }
    else
    {
        confess &log(ERROR, "unexpected xlog magic 0x" . sprintf("%X", $iMagic) . ' (unsupported PostgreSQL version?)',
                     ERROR_VERSION_NOT_SUPPORTED);
    }

    # Read flags
    sysread($hFile, $tBlock, 2) == 2
        or confess &log(ERROR, "unable to read xlog info");

    my $iFlag = unpack('S', $tBlock);

    $iFlag & 2
        or confess &log(ERROR, "expected long header in flags " . sprintf("%x", $iFlag));

    # Get the database system id
    sysseek($hFile, $iSysIdOffset, SEEK_CUR)
        or confess &log(ERROR, "unable to read padding");

    sysread($hFile, $tBlock, 8) == 8
        or confess &log(ERROR, "unable to read database system identifier");

    length($tBlock) == 8
        or confess &log(ERROR, "block is incorrect length");

    close($hFile);

    my $ullDbSysId = unpack('Q', $tBlock);

    &log(TRACE, sprintf("${strOperation}: WAL magic = 0x%X, database system id = ", $iMagic) . $ullDbSysId);

    return $strDbVersion, $ullDbSysId;
}

####################################################################################################################################
# walRange
#
# Generates a range of archive log file names given the start and end log file name.  For pre-9.3 databases, use bSkipFF to exclude
# the FF that prior versions did not generate.
####################################################################################################################################
sub walRange
{
    my $self = shift;
    my $strArchiveStart = shift;
    my $strArchiveStop = shift;
    my $bSkipFF = shift;

    # strSkipFF default to false
    $bSkipFF = defined($bSkipFF) ? $bSkipFF : false;

    if ($bSkipFF)
    {
        &log(TRACE, 'archive_list_get: pre-9.3 database, skipping log FF');
    }
    else
    {
        &log(TRACE, 'archive_list_get: post-9.3 database, including log FF');
    }

    # Get the timelines and make sure they match
    my $strTimeline = substr($strArchiveStart, 0, 8);
    my @stryArchive;
    my $iArchiveIdx = 0;

    if (substr($strArchiveStart, 0, 8) ne substr($strArchiveStop, 0, 8))
    {
        confess &log(ERROR, "Timelines between ${strArchiveStart} and ${strArchiveStop} differ");
    }

    # Iterate through all archive logs between start and stop
    push @stryArchive, $strArchiveStart;

    while ($stryArchive[@stryArchive - 1] ne $strArchiveStop)
    {
        push @stryArchive, $self->walNext($stryArchive[@stryArchive - 1], $bSkipFF);
    }

    &log(TRACE, "    archive_list_get: $strArchiveStart:$strArchiveStop (@stryArchive)");

    return @stryArchive;
}

####################################################################################################################################
# walNext
#
# Determines the next archive log in the sequence.
####################################################################################################################################
sub walNext
{
    my $self = shift;
    my $strArchivePrior = shift;
    my $bSkipFF = shift;

    # strSkipFF default to false
    $bSkipFF = defined($bSkipFF) ? $bSkipFF : false;

    # Get the timelines and make sure they match
    my $strTimeline = substr($strArchivePrior, 0, 8);

    # Iterate through all archive logs between start and stop
    my $iStartMajor = hex(substr($strArchivePrior, 8, 8));
    my $iStartMinor = hex(substr($strArchivePrior, 16, 8));

    # Increment minor
    $iStartMinor += 1;

    # If the minor is maxed out then increment major and reset the minor
    if ($bSkipFF && $iStartMinor == 255 || !$bSkipFF && $iStartMinor == 256)
    {
        $iStartMajor += 1;
        $iStartMinor = 0;
    }

    # Return the next archive name
    return uc(sprintf("${strTimeline}%08x%08x", $iStartMajor, $iStartMinor));
}

1;