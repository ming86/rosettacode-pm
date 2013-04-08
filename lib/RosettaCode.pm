use v5.14;
package RosettaCode;

our $VERSION = '0.0.1';

use MediaWiki::Bot;
use YAML::XS;

use App::Cmd::Setup ();
App::Cmd::Setup->import(-app);

package RosettaCode::Command;
App::Cmd::Setup->import(-command);

package RosettaCode;

use Module::Pluggable
  require     => 1,
  search_path => [ 'RosettaCode::Command' ];
RosettaCode->plugins;

package RosettaCode::Command::sync;
use Mo qw'build builder default xxx';
extends 'RosettaCode::Command';

use IO::All;

use constant abstract => 'Sync local mirror with remote RosettaCode wiki';
use constant usage_desc => 'rosettacode sync <target_directory> [<options>]';
use constant options => [qw( target )];

use constant TASKS_FILE => 'Cache/tasks.txt';
use constant LANGS_FILE => 'Cache/langs.txt';
use constant TASKS_CATEGORY => 'Category:Programming_Tasks';
use constant LANGS_CATEGORY => 'Category:Programming_Languages';
use constant CACHE_TIME => 24 * 60 * 60;    # 24 hours

has bot => (builder => 'build_bot');
has conf => (default => sub {
    my ($self) = @_;
    RosettaCode::Conf->new(root => $self->target);
});
has tasks => (builder => 'build_tasks');
has langs => (builder => 'build_langs');
has target => ();

sub validate_args {
    my ($self, $opts, $args) = @_;
    $self->usage_error("Sync requires a <target_directory> argument")
        unless @$args == 1;
    my $target = $args->[0];
    $self->usage_error("'$target' directory does not exist")
        unless -d $target;
    my $conffile = "$target/Conf/rosettacode.yaml";
    $self->usage_error("'$conffile' does not exist")
        unless -f $conffile;
    $self->{target} = $target;
}

sub execute {
    my ($self) = @_;
    $self->conf;        # Build the conf object, which sets up the environment.
    for my $lang (sort keys %{$self->langs}) {
        my $url = $lang;
        my $content = $self->fetch_lang($url);
        $self->write_file("Lang/$url/0DESCRIPTION", $content);
    }
    for my $task (sort keys %{$self->tasks}) {
        my $task_info = $self->tasks->{$task};
        my $content = $self->fetch_task($task_info->{url});
        $self->parse_task_page($task, $content);
    }
}

sub parse_description {
    my ($self, $content) = @_;
    $$content =~ s/\A\{\{task(?:\|(.*?))?\}\}(.*?\n)(?===\{\{)//s or return;
    my ($note, $text) = ($1, $2);
    my $original = $text;
    my $meta = $note ? {note => $note} : undef;
    while ($text =~ /\A\s*(?:\{\{requires|\[\[Category:)/) {
        $meta ||= {};
        if ($text =~ s/\A\s*\{\{requires\|(\w+)\}\}//) {
            $meta->{requires} ||= [];
            push @{$meta->{requires}}, $1;
        }
        elsif ($text =~ s/\A\s*\[\[Category:(\w[\w ]*)\]\]//) {
            $meta->{category} ||= [];
            push @{$meta->{category}}, $1;
        }
        else {
            $$content = $original . $$content;
            return;
        }
    }
    $text =~ s/\A\s*\n//;
    $text =~ s/ *$//mg;
    $text =~ s/\n*\z/\n/ if length($text);
    return ($text, $meta);
}

sub parse_task_page {
    my ($self, $task, $content) = @_;
    $content =~ s/\r//g;
    $content =~ s/\n?\z/\n/;
    my ($text, $meta) = $self->parse_description(\$content)
        or $self->parse_fail($task, $content);
    my $dir = $self->tasks->{$task}{url};
    my $file = $self->tasks->{$task}{file};
    $self->write_file("Task/$dir/0DESCRIPTION", $text);
    YAML::XS::DumpFile("Task/$dir/1META.yaml", $meta) if $meta;

    while (length $content) {
        my ($lang, @sections) = $self->parse_next_lang_section(\$content)
            or $self->parse_fail($task, $content);
        next unless $self->langs->{$lang};
        next unless @sections;
        unlink("Lang/$lang/$dir");
        io->link("Lang/$lang/$dir")
            ->assert->symlink("../../Task/$dir/$lang");
        my $first = shift @sections;
        my $ext = $self->langs->{$lang}->{ext};
        $self->write_file("Task/$dir/$lang/$file.$ext", $first);
        my $count = 2;
        for (@sections) {
            $self->write_file("Task/$dir/$lang/$file-$count.$ext", $_);
            $count++;
        }
    }
}

sub parse_next_lang_section {
    my ($self, $content) = @_;
    $$content =~ s/\A==\{\{header\|(.*?)\}\}(.*?\n)(?:\z|(?===\{\{))//s or return;
    my ($lang, $text) = ($1, $2);
    my $original = $text;
    my @sections;
    while ($text =~ s/<lang(?: [^>]+)?>(.*?)<\/lang>//s) {
        my $section = $1;
        $section =~ s/\A\s*\n//;
        $section =~ s/ *$//mg;
        $section =~ s/\n*\z/\n/ if length($section);
        push @sections, $section;
    }
    die $text . $lang if $text =~ /<lang/;
    return ($lang, @sections);
}

sub fetch_task {
    my ($self, $name) = @_;
    my $file = io->file("Cache/Task/$name");
    if ($file->exists and time - $file->mtime < CACHE_TIME) {
        return $file->all;
    }
    else {
        my $content = $self->bot->get_text($name);
        $file->assert->utf8->print($content);
        return $content;
    }
}

sub fetch_lang {
    my ($self, $name) = @_;
    $name = ":Category:$name";
    my $file = io->file("Cache/Lang/$name");
    if ($file->exists and time - $file->mtime < CACHE_TIME) {
        return $file->all;
    }
    else {
        my $content = $self->bot->get_text($name);
        $file->assert->utf8->print($content);
        return $content;
    }
}

sub build_tasks {
    my ($self) = @_;
    my $io = io->file(TASKS_FILE);
    my @task_list;
    if ($io->exists and time - $io->mtime < CACHE_TIME) {
         @task_list = $io->chomp->slurp;
    }
    else {
        @task_list = $self->bot->get_pages_in_category(TASKS_CATEGORY);
        $io->utf8->println($_) for @task_list;
    }
    my $tasks = YAML::XS::LoadFile('Conf/task.yaml');
    for my $task (keys %$tasks) {
        ($tasks->{$task}{url} = $task) =~ s/ /_/g;
        ($tasks->{$task}{file} = lc($task)) =~ s/[^a-z0-9]/_/g;
    }
    return $tasks;
}

sub build_langs {
    my ($self) = @_;
    my $io = io->file(LANGS_FILE);
    my @lang_list;
    if ($io->exists and time - $io->mtime < CACHE_TIME) {
         @lang_list = $io->chomp->slurp;
    }
    else {
        @lang_list = map {
            s/^Category://;
            $_;
        } $self->bot->get_pages_in_category(LANGS_CATEGORY);
        $io->utf8->println($_) for @lang_list;
    }
    my $langs = YAML::XS::LoadFile('Conf/lang.yaml');
    for my $lang (keys %$langs) {
        die $lang unless $langs->{$lang}{ext};
    }
    return $langs;
}

sub build_bot {
    my ($self) = @_;
    $self->conf->api_url =~ m!^(https?)://([^/]+)/(.*)/api.php$! or die;
    my ($protocol, $host, $path) = ($1, $2, $3);
    MediaWiki::Bot->new({
        assert => 'bot',
        protocol => $protocol,
        host => $host,
        path => $path,
    });
}

sub write_file {
    my ($self, $file, $content) = @_;
    io->file($file)->assert->utf8->print($content);
}

sub parse_fail {
    my ($self, $task, $content) = @_;
    die "Task '$task' parse failed:\n" . substr($content, 0, 200) . "\n";
}

package RosettaCode::Conf;
use Mo qw'build builder default xxx';

has root => ();
has api_url => ();
has task_list => ();
has lang_list => ();

sub BUILD {
    my ($self) = @_;
    my $root = $self->root;
    chdir $root or die "Can't chdir to '$root'";
    %$self = %{YAML::XS::LoadFile("Conf/rosettacode.yaml")};
}

1;

=encoding utf8

=head1 NAME

RosettaCode - An Application to interface with http://rosettacode.org

=head1 SYNOPSIS

From the command line:

    > rosettacode help
    > git clone git://github.com/acmeism/RosettaCode.git
    > cd RosettaCode
    > rosettacode sync --target=.

=head1 DESCRIPTION

RosettaCode.org is a fantastic wiki that contains ~ 650 programming tasks,
each implemented in up to ~ 500 programming languages.

This tool aims to make it easier for programmers to obtain and try the various
code samples.

At this point, the main function is to extract the code examples and put them
into a git repository on GitHub. You probably don't need to use this tool
yourself. You can just get the repository here:

    git clone git://github.com/acmeism/RosettaCode.git

=head1 AUTHOR

Ingy döt Net <ingy@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2013. Ingy döt Net.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See http://www.perl.com/perl/misc/Artistic.html

=cut