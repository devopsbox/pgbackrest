####################################################################################################################################
# COMMON THREADGROUP MODULE
####################################################################################################################################
package pgBackRest::Protocol::ThreadGroup;

use threads;
use strict;
use warnings FATAL => qw(all);
use Carp qw(confess);

use Exporter qw(import);
    our @EXPORT = qw();
use File::Basename;
use Scalar::Util qw(blessed);

use lib dirname($0) . '/../lib';
use pgBackRest::Common::Exception;
use pgBackRest::Common::Log;
use pgBackRest::Common::Wait;
use pgBackRest::Config::Config;
use pgBackRest::BackupFile;
use pgBackRest::RestoreFile;

####################################################################################################################################
# Module globals
####################################################################################################################################
my @oyThread;
my @oyMessageQueue;
my @oyCommandQueue;
my @oyResultQueue;
my @byThreadRunning;

####################################################################################################################################
# threadGroupCreate
####################################################################################################################################
sub threadGroupCreate
{
    # If thread-max is not defined then this operation does not use threads
    if (!(optionTest(OPTION_THREAD_MAX) && optionGet(OPTION_THREAD_MAX) > 1))
    {
        return;
    }

    # Get thread-max
    my $iThreadMax = optionGet(OPTION_THREAD_MAX);

    # Only create threads when thread-max > 1
    if ($iThreadMax > 1)
    {
        for (my $iThreadIdx = 0; $iThreadIdx < $iThreadMax; $iThreadIdx++)
        {
            push @oyCommandQueue, Thread::Queue->new();
            push @oyMessageQueue, Thread::Queue->new();
            push @oyResultQueue, Thread::Queue->new();
            push @oyThread, (threads->create(\&threadGroupThread, $iThreadIdx));
            push @byThreadRunning, false;
        }
    }
}

push @EXPORT, qw(threadGroupCreate);

####################################################################################################################################
# threadGroupThread
####################################################################################################################################
sub threadGroupThread
{
    my $iThreadIdx = shift;

    # When a KILL signal is received, immediately abort
    $SIG{'KILL'} = sub {threads->exit();};

    while (my $oCommand = $oyCommandQueue[$iThreadIdx]->dequeue())
    {
        # Exit thread
        if ($$oCommand{function} eq 'exit')
        {
            &log(TRACE, 'thread terminated');
            return;
        }

        &log(TRACE, "$$oCommand{function} thread started");
        my $oFile = undef;

        eval
        {
            # Get the protocol object
            my $oProtocol = protocolGet(undef, false, $iThreadIdx + 1);

            # Create a file object
            $oFile = new pgBackRest::File
            (
                optionGet(OPTION_STANZA),
                optionGet(OPTION_REPO_PATH),
                optionRemoteType(),
                $oProtocol,
                undef, undef,
                $iThreadIdx + 1
            );

            # Notify parent that init is complete
            threadMessage($oyResultQueue[$iThreadIdx], 'init');

            my $iDirection = $iThreadIdx % 2 == 0 ? 1 : -1;     # Size of files currently copied by this thread

            # Initialize the starting and current queue index based in the total number of threads in relation to this thread
            my $iQueueStartIdx = int((@{$$oCommand{param}{queue}} / $$oCommand{thread_total}) * $iThreadIdx);
            my $iQueueIdx = $iQueueStartIdx;

            # Keep track of progress (ignored for threaded backup and restore)
            my $lSizeCurrent = 0;

            # Loop through all the queues (exit when the original queue is reached)
            do
            {
                &log(TRACE, "reading queue ${iQueueIdx}, start queue ${iQueueStartIdx}");

                while (my $oMessage = ${$$oCommand{param}{queue}}[$iQueueIdx]->dequeue_nb())
                {
                    if ($$oCommand{function} eq 'restore')
                    {
                        restoreFile($oMessage, $$oCommand{param}{copy_time_begin}, $$oCommand{param}{delta}, $$oCommand{param}{force},
                                    $$oCommand{param}{backup_path}, $$oCommand{param}{source_compression},
                                    $$oCommand{param}{current_user}, $$oCommand{param}{current_group}, $oFile);
                    }
                    elsif ($$oCommand{function} eq 'backup')
                    {
                        # Result hash that can be passed back to the master process
                        my $oResult = {};

                        # Backup the file
                        ($$oResult{copied}, $lSizeCurrent, $$oResult{size}, $$oResult{repo_size}, $$oResult{checksum}) =
                            backupFile($oFile, $$oMessage{db_file}, $$oMessage{repo_file}, $$oCommand{param}{compress},
                                       $$oMessage{checksum}, $$oMessage{modification_time}, $$oMessage{size});

                        # Send a message to update the manifest
                        $$oResult{repo_file} = $$oMessage{repo_file};

                        $$oCommand{param}{result_queue}->enqueue($oResult);
                    }
                    else
                    {
                        confess &log(ERROR, "unknown command");
                    }

                    # Keep the protocol layer from timing out while checksumming
                    $oProtocol->keepAlive();
                }

                # Even numbered threads move up when they have finished a queue, odd numbered threads move down
                $iQueueIdx += $iDirection;

                # Reset the queue index when it goes over or under the number of queues
                if ($iQueueIdx < 0)
                {
                    $iQueueIdx = @{$$oCommand{param}{queue}} - 1;
                }
                elsif ($iQueueIdx >= @{$$oCommand{param}{queue}})
                {
                    $iQueueIdx = 0;
                }
            }
            while ($iQueueIdx != $iQueueStartIdx);

            # Notify parent of shutdown
            threadMessage($oyResultQueue[$iThreadIdx], 'shutdown');
            threadMessageExpect($oyMessageQueue[$iThreadIdx], 'continue');

            # Destroy the file object
            undef($oFile);

            # Notify the parent process of thread exit
            threadMessage($oyResultQueue[$iThreadIdx], 'complete');

            &log(TRACE, "$$oCommand{function} thread exiting");
        };

        if ($@)
        {
            my $oMessage = $@;

            threadMessage($oyResultQueue[$iThreadIdx], 'error');
            threadMessageExpect($oyMessageQueue[$iThreadIdx], 'continue');
            undef($oFile);
            threadMessage($oyResultQueue[$iThreadIdx], 'complete');

            if (blessed($oMessage) && $oMessage->isa('pgBackRest::Common::Exception'))
            {
                threadMessage($oyResultQueue[$iThreadIdx], $oMessage->code());
                threadMessage($oyResultQueue[$iThreadIdx], $oMessage->message());
            }
            else
            {
                threadMessage($oyResultQueue[$iThreadIdx], ERROR_UNKNOWN);
                threadMessage($oyResultQueue[$iThreadIdx], $oMessage);
            }
        }
    }
}

####################################################################################################################################
# threadMessage
####################################################################################################################################
sub threadMessage
{
    my $oQueue = shift;
    my $strMessage = shift;
    my $iThreadIdx = shift;

    # Send the message
    $oQueue->enqueue($strMessage);

    # Define calling context
    &log(TRACE, "sent message '${strMessage}' to " . (defined($iThreadIdx) ? 'thread ' . ($iThreadIdx + 1) : 'controller'));
}

####################################################################################################################################
# threadMessageExpect
####################################################################################################################################
sub threadMessageExpect
{
    my $oQueue = shift;
    my $strExpected = shift;
    my $iThreadIdx = shift;
    my $bNoBlock = shift;

    # Set timeout based on the message type
    my $iTimeout = defined($bNoBlock) ? undef: 600;

    # Define calling context
    my $strContext = defined($iThreadIdx) ? 'thread ' . ($iThreadIdx + 1) : 'controller';

    # Wait for the message
    my $strMessage;

    if (defined($iTimeout))
    {
        &log(TRACE, "waiting for '" . (defined($strExpected) ? $strExpected : '[undef]') . "' message from ${strContext}");

        my $oWait = waitInit($iTimeout);

        do
        {
            $strMessage = $oQueue->dequeue_nb();
        }
        while (!defined($strMessage) && waitMore($oWait));
    }
    else
    {
        $strMessage = $oQueue->dequeue_nb();

        return if !defined($strMessage);
    }

    # Throw an exeception when the message was not received
    if (!defined($strMessage) || (defined($strExpected) && $strMessage ne $strExpected))
    {
        confess &log(ASSERT, "expected message '$strExpected' from ${strContext} but " .
                             (defined($strMessage) ? "got '$strMessage'" : "timed out after ${iTimeout} second(s)"));
    }

    &log(TRACE, "got '" . (defined($strExpected) ? $strExpected : '[undef]') . "' message from ${strContext}");

    return $strMessage;
}

####################################################################################################################################
# threadGroupRun
####################################################################################################################################
sub threadGroupRun
{
    my $iThreadIdx = shift;
    my $strFunction = shift;
    my $oParam = shift;

    my %oCommand;
    $oCommand{function} = $strFunction;
    $oCommand{thread_total} = @oyThread;
    $oCommand{param} = $oParam;

    $oyCommandQueue[$iThreadIdx]->enqueue(\%oCommand);

    threadMessageExpect($oyResultQueue[$iThreadIdx], 'init', $iThreadIdx);
    $byThreadRunning[$iThreadIdx] = true;
}

push @EXPORT, qw(threadGroupRun);

####################################################################################################################################
# threadGroupComplete
#
# Wait for threads to complete.
####################################################################################################################################
sub threadGroupComplete
{
    my $self = shift;
    my $iTimeout = shift;
    my $bConfessOnError = shift;

    # Set defaults
    $bConfessOnError = defined($bConfessOnError) ? $bConfessOnError : true;

    # Wait for all threads to complete and handle errors
    my $iThreadComplete = 0;
    my $lTimeBegin = time();
    my $iFirstErrorCode;
    my $strFirstError;
    my $iFirstErrorThreadIdx;

    &log(TRACE, "waiting for " . @oyThread . " threads to complete");

    waitHiRes(.1);

    # If a timeout has been defined, make sure we have not been running longer than that
    if (defined($iTimeout))
    {
        if (time() - $lTimeBegin >= $iTimeout)
        {
            confess &log(ERROR, "threads have been running more than ${iTimeout} seconds, exiting...");
        }
    }

    for (my $iThreadIdx = 0; $iThreadIdx < @oyThread; $iThreadIdx++)
    {
        if ($byThreadRunning[$iThreadIdx])
        {
            my $strMessage = threadMessageExpect($oyResultQueue[$iThreadIdx], undef, $iThreadIdx, true);

            # Check for thread shutdown
            if (defined($strMessage) && $strMessage eq 'shutdown')
            {
                threadMessage($oyMessageQueue[$iThreadIdx], 'continue', $iThreadIdx);
                threadMessageExpect($oyResultQueue[$iThreadIdx], 'complete', $iThreadIdx);

                $byThreadRunning[$iThreadIdx] = false;
                $iThreadComplete++;
            }

            # Check for handled errors
            if (defined($strMessage) && $strMessage eq 'error')
            {
                threadMessage($oyMessageQueue[$iThreadIdx], 'continue', $iThreadIdx);
                threadMessageExpect($oyResultQueue[$iThreadIdx], 'complete', $iThreadIdx);

                $byThreadRunning[$iThreadIdx] = false;
                $iThreadComplete++;

                if (!defined($strFirstError))
                {
                    $iFirstErrorCode = threadMessageExpect($oyResultQueue[$iThreadIdx], undef, $iThreadIdx);
                    $strFirstError = threadMessageExpect($oyResultQueue[$iThreadIdx], undef, $iThreadIdx);
                    $iFirstErrorThreadIdx = $iThreadIdx;
                }
            }

            # Check for unhandled errors
            my $oError = $oyThread[$iThreadIdx]->error();

            if (defined($oError))
            {
                my $strError;

                if ($oError->isa('pgBackRest::Common::Exception'))
                {
                    $strError = $oError->message();
                }
                else
                {
                    $strError = $oError;
                    &log(ERROR, "thread " . ($iThreadIdx) . ": ${strError}");
                }

                if (!defined($strFirstError))
                {
                    $strFirstError = $strError;
                    $iFirstErrorThreadIdx = $iThreadIdx;
                }

                if ($byThreadRunning[$iThreadIdx])
                {
                    $byThreadRunning[$iThreadIdx] = false;
                    $iThreadComplete++;
                }
            }
        }
        else
        {
            $iThreadComplete++;
        }
    }

    # If there were errors then confess them
    if (defined($strFirstError) && $bConfessOnError)
    {
        confess &log(ERROR, 'error in thread ' . ($iFirstErrorThreadIdx + 1) . ": $strFirstError", $iFirstErrorCode);
    }

    # Return true if all threads have completed
    if ($iThreadComplete == @oyThread)
    {
        &log(DEBUG, 'all threads exited');
        return true;
    }

    return false;
}

push @EXPORT, qw(threadGroupComplete);

####################################################################################################################################
# threadGroupDestroy
####################################################################################################################################
sub threadGroupDestroy
{
    my $self = shift;

    &log(TRACE, "waiting for " . @oyThread . " threads to be destroyed");

    for (my $iThreadIdx = 0; $iThreadIdx < @oyThread; $iThreadIdx++)
    {
        if (defined($oyThread[$iThreadIdx]))
        {
            my %oCommand;
            $oCommand{function} = 'exit';

            $oyCommandQueue[$iThreadIdx]->enqueue(\%oCommand);
            waitHiRes(.1);

            if ($oyThread[$iThreadIdx]->is_running())
            {
                $oyThread[$iThreadIdx]->kill('KILL')->join();
                &log(TRACE, "thread ${iThreadIdx} killed");
            }
            elsif ($oyThread[$iThreadIdx]->is_joinable())
            {
                $oyThread[$iThreadIdx]->join();
                &log(TRACE, "thread ${iThreadIdx} joined");
            }

            undef($oyThread[$iThreadIdx]);
        }
    }

    &log(TRACE, @oyThread . " threads destroyed");

    return(@oyThread);
}

push @EXPORT, qw(threadGroupDestroy);

1;
