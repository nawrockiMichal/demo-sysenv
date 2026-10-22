#!/usr/bin/env bash
# getenv-to-value.sh - replace System.getenv("ENV_NAME") in Java code with Spring @Value fields
# backed by a properties file.
#
# Naming: ENV_NAME becomes the property key env.name (lower case, "_" -> "."). Spring maps the key
# back to ENV_NAME, so an environment variable on the machine still overrides the file.
#
# Usages that cannot safely become an injected field are left unchanged and reported:
#   - constructors, field initializers, initializer blocks (fields are injected after construction)
#   - static methods (instance fields are not reachable)
#   - nested types, interfaces, enums, records
#   - non-literal arguments, e.g. System.getenv(name)
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: getenv-to-value.sh [options] [project-dir]

Replaces System.getenv("ENV_NAME") with @Value("${env.name}") fields and adds the keys to a
properties file. Run it on a clean git tree so the changes are easy to review.

Options:
  -p, --properties FILE  properties file to write (relative to project-dir). Default:
                         src/test/resources/application.properties if every change is under src/test,
                         otherwise src/main/resources/application.properties
  -n, --dry-run          show what would change without writing anything
  --copy-env-values      write the current value of each environment variable into the file
                         (names that look like secrets always get a ${ENV_NAME} placeholder)
  --force                run even if no Spring dependency is found in the build file
  -h, --help             show this help

By default each key is written as  env.name=${ENV_NAME}  so behaviour is unchanged: the value still
comes from the environment until you replace the placeholder with a real value.
EOF
}

PROJECT=.
PROPS=""
DRY_RUN=0
COPY_ENV=0
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--properties) PROPS="${2:?missing value for $1}"; shift 2 ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        --copy-env-values) COPY_ENV=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) PROJECT="$1"; shift ;;
    esac
done

cd "$PROJECT"
command -v perl >/dev/null || { echo "perl is required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- Spring detection ---------------------------------------------------------------------------
BUILD_FILES=$(find . -maxdepth 3 \( -name pom.xml -o -name build.gradle -o -name build.gradle.kts \) \
    -not -path '*/target/*' -not -path '*/build/*' 2>/dev/null || true)
SPRING=none
if [ -n "$BUILD_FILES" ]; then
    if echo "$BUILD_FILES" | xargs grep -qs 'spring-boot'; then
        SPRING=boot
    elif echo "$BUILD_FILES" | xargs grep -qs 'org.springframework'; then
        SPRING=plain
    fi
fi
if [ "$SPRING" = none ] && [ "$FORCE" -eq 0 ]; then
    echo "No Spring dependency found in pom.xml/build.gradle: @Value would not be injected." >&2
    echo "Add Spring first, or re-run with --force." >&2
    exit 1
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "Warning: the git working tree has uncommitted changes; review the diff carefully."
    echo
fi

# --- Find Java files ----------------------------------------------------------------------------
grep -rlE --include='*.java' \
    --exclude-dir=target --exclude-dir=build --exclude-dir=.git --exclude-dir=.gradle \
    --exclude-dir=node_modules --exclude-dir=out \
    'System[[:space:]]*\.[[:space:]]*getenv' . > "$WORK/files" 2>/dev/null || true

if [ ! -s "$WORK/files" ]; then
    echo "No System.getenv usages found in $(pwd)."
    exit 0
fi

# --- Java rewriting (perl) ----------------------------------------------------------------------
# Prints tab-separated report lines:
#   R file line ENV key field   replaced
#   S file line reason snippet  skipped
#   B file class status         bean status of an edited class
cat > "$WORK/rewrite.pl" <<'PERL'
use strict;
use warnings;

my ($file, $dry) = @ARGV;
open my $in, '<', $file or die "$file: $!";
my $src = do { local $/; <$in> };
close $in;

# Blank out comments and string/char literal contents (keeping offsets and newlines)
# so code structure can be scanned safely.
sub blank { my $seg = substr($_[0], $_[1], $_[2] - $_[1]); $seg =~ s/[^\n]/ /g; substr($_[0], $_[1], $_[2] - $_[1]) = $seg; }
sub mask {
    my ($s) = @_;
    my $m = $s;
    my $n = length $s;
    my $i = 0;
    while ($i < $n) {
        my $c = substr($s, $i, 1);
        my $c2 = substr($s, $i, 2);
        if ($c2 eq '//') { my $j = index($s, "\n", $i); $j = $n if $j < 0; blank($m, $i, $j); $i = $j; next; }
        if ($c2 eq '/*') { my $j = index($s, '*/', $i + 2); $j = $j < 0 ? $n : $j + 2; blank($m, $i, $j); $i = $j; next; }
        if (substr($s, $i, 3) eq '"""') {
            my $j = index($s, '"""', $i + 3); $j = $n - 3 if $j < 0;
            blank($m, $i + 3, $j); $i = $j + 3; next;
        }
        if ($c eq '"' || $c eq "'") {
            my $j = $i + 1;
            while ($j < $n) {
                my $d = substr($s, $j, 1);
                if ($d eq '\\') { $j += 2; next; }
                last if $d eq $c || $d eq "\n";
                $j++;
            }
            $j = $n if $j > $n;
            blank($m, $i + 1, $j); $i = $j + 1; next;
        }
        $i++;
    }
    return $m;
}

my $masked = mask($src);

my @occ;
while ($masked =~ /\bSystem\s*\.\s*getenv\s*\(/g) {
    push @occ, { start => $-[0], open => $+[0] };
}
exit 0 unless @occ;

# Record the stack of enclosing "{" headers for every occurrence.
my @stack;
my $sep = 0;
my $k = 0;
my $n = length $masked;
for (my $i = 0; $i < $n && $k < @occ; $i++) {
    while ($k < @occ && $occ[$k]{start} == $i) { $occ[$k]{stack} = [@stack]; $k++; }
    my $c = substr($masked, $i, 1);
    if ($c eq '{') {
        my $h = substr($masked, $sep, $i - $sep);
        $h =~ s/\s+/ /g; $h =~ s/^ //; $h =~ s/ $//;
        push @stack, { header => $h, pos => $i };
        $sep = $i + 1;
    } elsif ($c eq '}') {
        pop @stack; $sep = $i + 1;
    } elsif ($c eq ';') {
        $sep = $i + 1;
    }
}

sub strip_annotations {
    my ($h) = @_;
    1 while $h =~ s/\@\w+(?:\s*\.\s*\w+)*\s*\((?:[^()]|\((?:[^()])*\))*\)//g;
    $h =~ s/\@\w+(?:\s*\.\s*\w+)*//g;
    $h =~ s/^\s+|\s+$//g;
    return $h;
}

my @src_lines = split /\n/, $src, -1;
sub line_of { my $p = shift; return 1 + (substr($src, 0, $p) =~ tr/\n//); }
sub snippet { my $l = $src_lines[$_[0] - 1] // ''; $l =~ s/^\s+|\s+$//g; $l =~ s/\t/ /g; return $l; }

my (@edits, %classes);
for my $o (@occ) {
    my $line = line_of($o->{start});
    my $skip = sub { print join("\t", 'S', $file, $line, $_[0], snippet($line)), "\n"; };

    my $rest = substr($src, $o->{open});
    unless ($rest =~ /\A\s*"((?:[^"\\\n]|\\.)*)"\s*\)/) { $skip->('argument is not a string literal'); next; }
    my $env = $1;
    my $end = $o->{open} + $+[0];

    my @st = @{ $o->{stack} || [] };
    unless (@st) { $skip->('not inside a class'); next; }
    my $top = strip_annotations($st[0]{header});
    unless ($top =~ /\bclass\s+(\w+)/) { $skip->('inside an interface, enum, record or annotation'); next; }
    my $cls = $1;
    if (@st == 1) { $skip->('field initializer: @Value fields are injected after the object is created'); next; }
    my $m = strip_annotations($st[1]{header});
    if ($m =~ /\b(?:class|interface|enum|record)\b/) { $skip->('inside a nested type'); next; }
    if ($m =~ /=/) { $skip->('field initializer: @Value fields are injected after the object is created'); next; }
    if ($m eq '' || $m eq 'static') { $skip->('initializer block: @Value fields are injected after the object is created'); next; }
    if ($m =~ /\bstatic\b/) { $skip->('static method: instance fields are not reachable'); next; }
    if ($m =~ /(?:^|[\s>])\Q$cls\E\s*\(/) {
        $skip->('constructor: @Value fields are injected after the constructor runs; use a @Value constructor parameter');
        next;
    }

    (my $key = lc $env) =~ s/[^a-z0-9]+/./g;
    $key =~ s/^\.+|\.+$//g;
    if ($key eq '') { $skip->('environment variable name has no usable characters'); next; }

    my $cpos = $st[0]{pos};
    $classes{$cpos} //= { name => $cls, header => $st[0]{header}, envs => {}, order => [] };
    my $c = $classes{$cpos};
    push @{ $c->{order} }, $env unless exists $c->{envs}{$env};
    $c->{envs}{$env} //= { key => $key };
    push @edits, { pos => $o->{start}, end => $end, env => $env, cpos => $cpos, line => $line };
}

exit 0 unless @edits;

# Use the fully-qualified annotation if another Value class is imported (e.g. lombok.Value).
my $spring_value = 'org.springframework.beans.factory.annotation.Value';
my $has_import = $src =~ /^\s*import\s+\Q$spring_value\E\s*;/m
    || $src =~ /^\s*import\s+org\.springframework\.beans\.factory\.annotation\.\*\s*;/m;
my $other_value = $src =~ /^\s*import\s+(?!org\.springframework\.beans\.factory\.annotation\.)[\w.]+\.Value\s*;/m;
my $ann = $other_value ? "\@$spring_value" : '@Value';

# Identifiers already in use as variables; method names (followed by "(") may share a name with a field.
my %used = map { $_ => 1 } ($masked =~ /\b([A-Za-z_]\w*)\b(?!\s*\()/g);
my @inserts;
for my $cpos (sort { $a <=> $b } keys %classes) {
    my $c = $classes{$cpos};
    my $indent = substr($src, $cpos + 1) =~ /\A[^\n]*\n(?:[ \t]*\n)*([ \t]+)\S/ ? $1 : '    ';
    my $text = '';
    for my $env (@{ $c->{order} }) {
        my $e = $c->{envs}{$env};
        # Reuse a field from an earlier run that already binds this key.
        if ($src =~ /\@(?:\Q$spring_value\E|Value)\(\s*"\$\{\Q$e->{key}\E\}"\s*\)\s*(?:(?:private|protected|public|final)\s+)*String\s+(\w+)\s*;/) {
            $e->{field} = $1;
            next;
        }
        my @parts = grep { length } split /[^A-Za-z0-9]+/, lc $env;
        my $field = join '', $parts[0], map { ucfirst } @parts[1 .. $#parts];
        $field = "env\u$field" if $field =~ /^\d/;
        # Avoid clashing with any identifier in the file (fields, locals, parameters).
        my $base = $field;
        my $suffix = 0;
        while ($used{$field}) { $suffix++; $field = $base . 'Value' . ($suffix > 1 ? $suffix : ''); }
        $used{$field} = 1;
        $e->{field} = $field;
        $text .= "\n\n${indent}${ann}(\"\${$e->{key}}\")\n${indent}private String $field;";
    }
    if ($text ne '') {
        # Keep a blank line between the new fields and the existing first member.
        $text .= "\n" unless substr($src, $cpos + 1) =~ /\A[ \t]*\n[ \t]*\n/;
        push @inserts, { pos => $cpos + 1, end => $cpos + 1, text => $text };
    }

    my $h = $c->{header};
    my $status = $h =~ /\@(?:Component|Service|Repository|Controller|RestController|Configuration)\b/ ? 'bean'
               : $src =~ /^\s*import\s+io\.cucumber\.java/m ? 'cucumber-glue'
               : 'not-a-bean';
    print join("\t", 'B', $file, $c->{name}, $status), "\n";
}

for my $e (@edits) {
    my $info = $classes{ $e->{cpos} }{envs}{ $e->{env} };
    $e->{text} = $info->{field};
    print join("\t", 'R', $file, $e->{line}, $e->{env}, $info->{key}, $info->{field}), "\n";
}

my $out = $src;
for my $e (sort { $b->{pos} <=> $a->{pos} } @edits, @inserts) {
    substr($out, $e->{pos}, $e->{end} - $e->{pos}) = $e->{text};
}

if (!$has_import && !$other_value) {
    my $imp = "import $spring_value;\n";
    my $last_import;
    $last_import = $+[0] while $out =~ /^[ \t]*import\s[^\n]*;[ \t]*\n/mg;
    if (defined $last_import) {
        substr($out, $last_import, 0) = $imp;
    } elsif ($out =~ /^[ \t]*package\s[^\n]*;[ \t]*\n/m) {
        my $p = $+[0];
        substr($out, $p, 0) = "\n$imp";
    } else {
        $out = $imp . "\n" . $out;
    }
}

unless ($dry) {
    open my $fh, '>', $file or die "$file: $!";
    print $fh $out;
    close $fh;
}
PERL

while IFS= read -r f; do
    perl "$WORK/rewrite.pl" "$f" "$DRY_RUN" >> "$WORK/report"
done < "$WORK/files"
touch "$WORK/report"

grep '^R' "$WORK/report" > "$WORK/replaced" || true
grep '^S' "$WORK/report" > "$WORK/skipped" || true
grep '^B' "$WORK/report" > "$WORK/beans" || true

# --- Properties file ----------------------------------------------------------------------------
if [ -z "$PROPS" ]; then
    if [ -s "$WORK/replaced" ] && ! cut -f2 "$WORK/replaced" | grep -qv '^\./src/test/'; then
        PROPS=src/test/resources/application.properties
    else
        PROPS=src/main/resources/application.properties
    fi
fi

cut -f4,5 "$WORK/replaced" | sort -u > "$WORK/keys" || true
: > "$WORK/props-add"
while IFS="$(printf '\t')" read -r env key; do
    [ -n "$key" ] || continue
    key_re=$(printf '%s' "$key" | sed 's/\./\\./g')
    if [ -f "$PROPS" ] && grep -qE "^[[:space:]]*${key_re}[[:space:]]*[=:]" "$PROPS"; then
        continue
    fi
    value="\${$env}"
    if [ "$COPY_ENV" -eq 1 ] && printenv "$env" >/dev/null 2>&1 \
        && ! printf '%s' "$env" | grep -qiE 'KEY|SECRET|PASSWORD|PASSWD|PWD|TOKEN|CREDENTIAL|CONNECTION|PRIVATE|AUTH'; then
        value=$(printenv "$env" | sed 's/\\/\\\\/g')
    fi
    printf '%s=%s\n' "$key" "$value" >> "$WORK/props-add"
done < "$WORK/keys"

if [ -s "$WORK/props-add" ] && [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$(dirname "$PROPS")"
    if [ -s "$PROPS" ] && [ -n "$(tail -c1 "$PROPS")" ]; then echo >> "$PROPS"; fi
    { [ -s "$PROPS" ] && echo; echo "# Moved from System.getenv by getenv-to-value.sh"; cat "$WORK/props-add"; } >> "$PROPS"
fi

# --- Report -------------------------------------------------------------------------------------
[ "$DRY_RUN" -eq 1 ] && echo "DRY RUN - nothing was written." && echo

if [ -s "$WORK/replaced" ]; then
    echo "Replaced ($(wc -l < "$WORK/replaced" | tr -d ' ')):"
    while IFS="$(printf '\t')" read -r _ f line env key field; do
        echo "  ${f#./}:$line  System.getenv(\"$env\") -> $field  @Value(\"\${$key}\")"
    done < "$WORK/replaced"
    echo
fi

if [ -s "$WORK/props-add" ]; then
    echo "Properties added to $PROPS:"
    sed 's/^/  /' "$WORK/props-add"
    echo
fi

if [ -s "$WORK/skipped" ]; then
    echo "Left unchanged - fix by hand ($(wc -l < "$WORK/skipped" | tr -d ' ')):"
    while IFS="$(printf '\t')" read -r _ f line reason snip; do
        echo "  ${f#./}:$line  $reason"
        echo "      $snip"
    done < "$WORK/skipped"
    echo
fi

WARN=0
while IFS="$(printf '\t')" read -r _ f cls status; do
    case "$status" in
        not-a-bean)
            [ $WARN -eq 0 ] && echo "Warnings:" && WARN=1
            echo "  ${f#./}: $cls has no @Component/@Service/@Configuration; @Value is only injected into Spring beans." ;;
        cucumber-glue)
            [ $WARN -eq 0 ] && echo "Warnings:" && WARN=1
            echo "  ${f#./}: $cls is Cucumber glue; @Value is only injected when cucumber-spring is on the classpath." ;;
    esac
done < "$WORK/beans"

if [ -s "$WORK/replaced" ]; then
    props_name=$(basename "$PROPS")
    if [ "$SPRING" = boot ]; then
        case "$props_name" in
            application.properties|application-*.properties) ;;
            *)
                [ $WARN -eq 0 ] && echo "Warnings:" && WARN=1
                echo "  Spring Boot only loads application*.properties automatically; add @PropertySource(\"classpath:$props_name\")." ;;
        esac
    elif ! grep -rqs --include='*.java' "@PropertySource.*$props_name" . ; then
        [ $WARN -eq 0 ] && echo "Warnings:" && WARN=1
        echo "  Plain Spring does not load $props_name by itself. Add to a @Configuration class:"
        echo "      @PropertySource(\"classpath:$props_name\")"
        echo "      @Bean public static PropertySourcesPlaceholderConfigurer propertySourcesPlaceholderConfigurer() {"
        echo "          return new PropertySourcesPlaceholderConfigurer();"
        echo "      }"
    fi
fi
[ $WARN -eq 1 ] && echo

echo "Note: System.getenv returned null for a missing variable; @Value fails at startup instead."
echo "Compile and run the tests to check the result (e.g. mvn test or ./gradlew test)."
