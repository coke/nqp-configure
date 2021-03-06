class Makefile {
    has @!macros;
    has %!macro-lookup;
    has @!targets;

    method BUILD(:@macros, :@targets) {
        @!macros := @macros;
        @!targets := @targets;
        %!macro-lookup := nqp::hash();

        for @!macros -> $macro {
            %!macro-lookup{$macro.Str} := $macro;
        }
    }

    class Macro {
        has $!name;
        has $!command;
        method name() { $!name }
        method Str() { '$(' ~ $!name ~ ')' }
        method expand() {
            $!command;
        }
    }

    method Str() {
        "targets: " ~ nqp::elems(@!targets);
    }

    method targets() {
        @!targets
    }

    method target($name) {
        for @!targets -> $target {
            return $target
                if self.expand-macros($target.name) eq $name;
        }
        Nil
    }

    sub file-exists($name) {
        nqp::stat(nqp::unbox_s($name), nqp::const::STAT_EXISTS)
    }

    sub file-modified($name) {
        nqp::stat_time(nqp::unbox_s($name), nqp::const::STAT_MODIFYTIME)
    }

    sub split-names($names) {
        $names := subst($names, /"\\"\n\h*/, ' ', :global);
        nqp::split(' ', $names)
    }

    method expand-macros($string) {
        return self.expand-macros($string.expand) if $string ~~ Makefile::Macro;
        subst(
            $string,
            /('$('\w+')')/,
            sub ($/) {
                nqp::existskey(%!macro-lookup, $/[0])
                    ?? self.expand-macros(%!macro-lookup{$/[0]}.expand)
                    !! ''
            },
            :global
        )
    }

    class Builder {
        my class Queue is repr('ConcBlockingQueue') { }

        has $!makefile;
        has $!queue;
        has $!job-tree;

        my class Job {
            has $!target;
            has $!name;
            has int $!status;
            has @!prerequisites;
            has $!modified;

            method target() { $!target }
            method name() { $!name }
            method status() { $!status }
            method set-status($new-status) { $!status := $new-status }
            method prerequisites() { @!prerequisites }
            method modified() { $!modified }
            method set-modified($modified) { $!modified := $modified }
        }

        method build($target-name) {
            $!queue := nqp::create(Queue);
            $!job-tree := self.create-job($target-name);
            my $j := 3;
            while $j-- {
                my $next-job := self.find-next-job($!job-tree);
                self.build-job($next-job) if $next-job;
            }
            until $!job-tree.status == 2 {
                if nqp::shift($!queue) -> $task {
                    if nqp::list($task) {
                        my $code := nqp::shift($task);
                        $code(|$task);
                    }
                    else {
                        $task();
                    }
                }
            }
        }

        method create-job($target-name, %jobs = nqp::hash()) {
            my $target := $!makefile.target($target-name);
            if $target {
                my @prerequisites;
                for $target.prerequisites -> $prerequisite {
                    my $names := $!makefile.expand-macros($prerequisite);
                    for split-names($names) {
                        my $job;
                        if nqp::existskey(%jobs, $_) {
                            $job := %jobs{$_};
                        }
                        else {
                            %jobs{$_} := $job := self.create-job($_, %jobs);
                        }
                        nqp::push(@prerequisites, $job) if $job;
                    }
                }
                return Job.new(:$target, :name($target-name), :@prerequisites);
            }
            elsif $target-name {
                nqp::die("Unknown target $target-name") unless file-exists($target-name);
                return Job.new(:name($target-name));
            }
            return Nil;
        }

        method find-next-job($job-tree) {
            if $job-tree.status == 0 {
                my $buildable := 1;
                for $job-tree.prerequisites -> $prerequisite {
                    $buildable := 0 if $prerequisite.status < 2;
                    my $job := self.find-next-job($prerequisite);
                    return $job if $job;
                }
                return $job-tree if $buildable;
            }
            return Nil;
        }

        method run($command, $config) {
            my $task := nqp::spawnprocasync($!queue, $command, nqp::cwd(), nqp::getenvhash(), $config);
            nqp::permit($task, 1, -1);
            nqp::permit($task, 2, -1);
        }

        method run-next-command($job, @recipe) {
            my $command := @recipe[0];
            my $check-exit-status := 1;
            if nqp::substr($command, 0, 1) eq '-' {
                $command := nqp::substr($command, 1);
                $check-exit-status := 0;
            }

            my $is-windows := nqp::backendconfig()<osname> eq 'MSWin32';
            my $args := $is-windows ?? nqp::list(nqp::getenvhash()<ComSpec>, '/c', $command)
                !! nqp::list('/bin/sh', '-c', $command);

            my $config := nqp::hash();
            $config<done> := -> $status {
                nqp::die("Got $status from $args") if $check-exit-status && $status != 0;
                nqp::shift(@recipe);
                if @recipe {
                    self.run-next-command($job, @recipe);
                }
                else {
                    if file-exists($job.name) {
                        $job.set-modified(file-modified($job.name));
                    }
                    $job.set-status(2);

                    my $next-job := self.find-next-job($!job-tree);
                    self.build-job($next-job) if $next-job;
                }
            }

            if nqp::substr($command, 0, 5) eq '@echo' {
                say(nqp::substr($command, 6));
                $config<done>(0);
                return;
            }

            note($command);
            self.run($args, $config);
        }

        method build-job($job) {
            $job.set-status(1);
            my $newest := 0;
            for $job.prerequisites -> $prerequisite {
                my $modified := $prerequisite.modified;
                $newest := $modified if $modified > $newest;
            }
            my $modified := file-exists($job.name) ?? file-modified($job.name) !! 0;
            if $modified == 0 || $newest > $modified {
                my @recipe;
                for $job.target.recipe -> $command {
                    $command := $!makefile.expand-macros($command);
                    nqp::push(@recipe, $command);
                }

                if @recipe {
                    return self.run-next-command($job, @recipe);
                }
            }
            $job.set-status(2); # nothing to do actually, so mark it as done immediately
            $job.set-modified(file-exists($job.name) ?? file-modified($job.name) !! nqp::time_n());
            my $next-job := self.find-next-job($!job-tree);
            self.build-job($next-job) if $next-job;
        }
    }

    method make($target-name) {
        Makefile::Builder.new(:makefile(self)).build($target-name);
    }
}

grammar Makefile::Grammar {
    method panic ( $msg ) {
        nqp::die("Can't parse file: $msg");
    }

    token TOP {
        [
                \n
                || <empty-line>
                || <comment>
                || <target-definition>
                || <macro-definition>
                || <garbage> { self.panic("unrecognized line «{$<garbage>[0]}»") }
        ]+
        \s*
    }
    token garbage {
        ^^ \s* \S \N*
    }
    token empty-line {
        ^^ \h* \n
    }
    token comment {
        ^^
        \h*
        '#'
        \N*
    }
    token target-definition {
        ^^
        [<target>+ % \h+] \h* ':' \h* <prerequisites> \n
    	<recipe>?
    }
    token macro-definition {
        <macro-assign>
    }
    token macro-assign {
        <target> \h* '=' \h* <command>
    }
    token target {
        <macro>
        | <[\w . / * \- \$\(\)]>+
    }
    token macro {
        '$(' \w+ ')'
    }
    token recipe {
        [
            <comment> \n
            || <recipe-line>
        ]+
    }
    token prerequisites {
    	[<target>\h* | <.continuation>]*
    }
    token recipe-line {
        ^^
        \t <command>
    	\n
    }
    token command {
        [ <.continuation> || \N]*
    }
    token continuation {
        "\\" \n \h*
    }
}

class Makefile::Target {
    has $!name;
    has @!prerequisites;
    has @!recipe;
    method name() {
        $!name
    }
    method prerequisites() {
        @!prerequisites
    }
    method recipe() {
        @!recipe
    }
    method Str() {
        $!name
    }
}

class Makefile::Actions {
    has %!macros;

    method TOP($/) {
        my @targets;
        for $<target-definition> -> $definition {
            for $definition.ast -> $subtarget {
                nqp::push(@targets, $subtarget);
            }
        }
        my @macros;
        for $<macro-definition> -> $definition {
            nqp::push(@macros, $definition.ast);
        }
        make Makefile.new(
            :@macros,
            :@targets,
        );
    }
    method comment($/) {
    }
    method target-definition($/) {
        my @targets;
        my @prerequisites := $<prerequisites>.ast;
        my @recipe;
        @recipe := $<recipe>.ast if $<recipe>;
        for $<target> -> $target {
            nqp::push(
                @targets,
                Makefile::Target.new(
                    :name($target.ast),
                    :@prerequisites,
                    :@recipe,
                ),
            );
        }
        make @targets;
    }
    method macro-definition($/) {
        my $macro := $<macro-assign>.ast;
        %!macros{'$(' ~ $macro.name ~ ')'} := $macro;
        make $macro;
    }
    method macro-assign($/) {
        make Makefile::Macro.new(:name($<target>.Str), :command($<command>.ast));
    }
    method target($/) {
        make $<macro> ?? $<macro>.ast !! $/.Str
    }
    method macro($/) {
        make %!macros{$/.Str};
    }
    method recipe($/) {
        my @recipe;
        nqp::push(@recipe, $_.ast) for $<recipe-line>;
        make @recipe;
    }
    method prerequisites($/) {
        my @targets;
        for $<target> -> $target {
            nqp::push(@targets, $target.ast);
        }
        make @targets;
    }
    method recipe-line($/) {
        make $<command>.ast;
    }
    method command($/) {
        make $/.Str;
    }
    method continuation($/) {
    }
}

sub MAIN(*@ARGS) {
    my $makefile := "Makefile";
    my $handle := open($makefile, :r);
    my $make := Makefile::Grammar.parse($handle.slurp, :actions(Makefile::Actions.new));

    if nqp::elems(@ARGS) < 2 {
        for $make.ast.targets -> $target {
            return $make.ast.make($target.name) if nqp::substr($target.name, 0, 1) ne '.';
        }
    }
    elsif @ARGS[1] eq 'help' && !$make.ast.target(@ARGS[1]) {
        say("Targets:");
        say($make.ast.expand-macros($_.name)) for $make.ast.targets;
    }
    else {
        $make.ast.make(@ARGS[1]);
    }
}
