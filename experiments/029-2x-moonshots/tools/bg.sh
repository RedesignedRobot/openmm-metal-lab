#!/bin/sh
# Runs on the M3 Ultra: starts one command detached and prints its pid.
# usage: bg.sh <logfile> <command> [args...]
# The command runs under nohup with stdout and stderr in <logfile> and stdin from /dev/null, so it
# survives an ssh drop and holds none of ssh's fds: `ssh "$STUDIO" bg.sh ...` returns at once.
# It is plain sh, so zsh's bg_nice never renices the job (a zsh `&` over ssh gives nice 5, and
# gate.sh refuses to run at nice 5). The job inherits bg.sh's own nice, so bg.sh refuses to start
# when that isn't 0: call it in the foreground, not from a background job.
set -eu
[ $# -ge 2 ] || { echo "usage: bg.sh <logfile> <command> [args...]" >&2; exit 2; }
log="$1"
shift
[ -d "$(dirname "$log")" ] || { echo "bg.sh: no directory for $log" >&2; exit 2; }
command -v "$1" > /dev/null 2>&1 || { echo "bg.sh: cannot run $1" >&2; exit 2; }
nice_now="$(ps -o nice= -p $$ | tr -d ' ')"
[ "$nice_now" = 0 ] || { echo "bg.sh: running at nice $nice_now, not 0; call it in the foreground" >&2; exit 3; }
# The job starts in a new session (setsid): the Codex exec tool kills its call's process group
# when the call returns, and nohup alone does not leave that group. bg.sh returns only after the
# child has called setsid and exec'd (the close-on-exec pipe reaches EOF), so no race remains.
# fd 3 carries the pid back; the child closes it so the caller's $(...) does not wait on the job.
pid=$(/usr/bin/perl -e '
    use POSIX ();
    pipe(my $r, my $w) or die "bg.sh: pipe: $!\n";
    defined(my $pid = fork) or die "bg.sh: fork: $!\n";
    if ($pid == 0) {
        close $r;
        POSIX::setsid() or die "bg.sh: setsid: $!\n";
        POSIX::close(3);
        $SIG{HUP} = "IGNORE";
        exec @ARGV;
        print $w "exec $ARGV[0]: $!";
        POSIX::_exit(127);
    }
    close $w;
    my $err = do { local $/; <$r> };
    die "bg.sh: $err\n" if length $err;
    open(my $out, ">&=", 3) or die "bg.sh: fd 3: $!\n";
    print $out "$pid\n";
' "$@" 3>&1 > "$log" 2>&1 < /dev/null) || { echo "bg.sh: launch failed, see $log" >&2; exit 1; }
echo "$pid"
