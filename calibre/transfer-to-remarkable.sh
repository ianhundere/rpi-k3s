#!/bin/bash

# default config
REMARKABLE_USB="root@10.11.99.1"
REMARKABLE_WIFI="root@192.168.3.76"
REMARKABLE_HOST=${REMARKABLE_HOST:-"remarkable"}
REMARKABLE_DIR=${REMARKABLE_DIR:-"/home/root/.local/share/remarkable/xochitl"}
TIMEOUT=${TIMEOUT:-5}
SUPPORTED_FORMATS="pdf|epub"
XOCHITL_SERVICE="xochitl"

show_usage() {
    echo "Usage: $(basename "$0") [OPTIONS] <directory-with-books>"
    echo
    echo "Options:"
    echo "  -h, --help          Show this help message"
    echo "  --purge-except PATTERN    Remove all files except those matching PATTERN"
    echo "  --remove FILE       Remove specific file from reMarkable"
    echo "  -r, --restart       Restart xochitl after transfer (default: true)"
    echo "  -q, --quiet         Suppress non-error output"
    echo
    echo "Examples:"
    echo "  $(basename "$0") ~/Desktop/Books                                    # Upload all books from directory"
    echo "  $(basename "$0") --purge-except \"Quick sheets|Notebook tutorial\"  # Keep only matching files"
    echo "  $(basename "$0") --remove \"My Book.pdf\"                          # Remove specific file"
    echo "  $(basename "$0") -q ~/Desktop/Books                                # Quiet mode"
    exit 1
}

log() {
    [ "$quiet" = true ] || echo "$@"
}

# manage xochitl service
manage_xochitl() {
    local action="$1"
    ssh_cmd "systemctl $action $XOCHITL_SERVICE"
}

# helper func for ssh with timeout
ssh_cmd() {
    ssh -o ConnectTimeout=$TIMEOUT "$REMARKABLE_HOST" "$@"
}

# creat temp dir with cleanup trap
create_temp_dir() {
    local tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT
    echo "$tmpdir"
}

transfer_file() {
    local file="$1"
    local tmpdir="$2"
    local filename=$(basename "$file")
    local extension="${filename##*.}"
    local title="${filename%.*}"
    local uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # validate file type
    if [[ ! "${extension,,}" =~ ^($SUPPORTED_FORMATS)$ ]]; then
        log "Unsupported file type: $extension"
        return 1
    fi

    # skip if file exists
    if file_exists_on_remarkable "$title"; then
        log "Skipping: $title (already exists)"
        return
    fi

    log "Transferring: $title"

    # copy file
    cp -- "$file" "${tmpdir}/${uuid}.${extension}"

    # create metadata
    cat <<EOF >"${tmpdir}/${uuid}.metadata"
{
    "deleted": false,
    "lastModified": "$(date +%s)000",
    "metadatamodified": false,
    "modified": false,
    "parent": "",
    "pinned": false,
    "synced": false,
    "type": "DocumentType",
    "version": 1,
    "visibleName": "$title"
}
EOF

    # create content based on type
    if [ "$extension" = "pdf" ]; then
        cat <<EOF >"${tmpdir}/${uuid}.content"
{
    "extraMetadata": {},
    "fileType": "pdf",
    "fontName": "",
    "lastOpenedPage": 0,
    "lineHeight": -1,
    "margins": 100,
    "pageCount": 1,
    "textScale": 1,
    "transform": {
        "m11": 1, "m12": 1, "m13": 1,
        "m21": 1, "m22": 1, "m23": 1,
        "m31": 1, "m32": 1, "m33": 1
    }
}
EOF
        # create req dirs
        mkdir -p "${tmpdir}/${uuid}.cache"
        mkdir -p "${tmpdir}/${uuid}.highlights"
        mkdir -p "${tmpdir}/${uuid}.thumbnails"

    elif [ "$extension" = "epub" ]; then
        cat <<EOF >"${tmpdir}/${uuid}.content"
{
    "fileType": "epub"
}
EOF
    else
        echo "Unsupported file type: $extension"
        return 1
    fi

    # transfer files
    scp -r "${tmpdir}/${uuid}"* "$REMARKABLE_HOST:$REMARKABLE_DIR/"
}

file_exists_on_remarkable() {
    local FILENAME="$1"
    log "Checking if '$FILENAME' exists..."
    if ssh_cmd "grep -l \"${FILENAME}\" ${REMARKABLE_DIR}/*.metadata" &>/dev/null; then
        log "Found existing file with title: $FILENAME"
        return 0
    fi
    log "No existing file found with title: $FILENAME"
    return 1
}

remove_file() {
    local FILE="$1"
    local TITLE=$(basename "${FILE%.*}")

    log "Looking for: $TITLE"
    local UUID=$(ssh_cmd "grep -l \"${TITLE}\" ${REMARKABLE_DIR}/*.metadata" | head -n1 | xargs basename | cut -d. -f1)

    if [ -n "$UUID" ]; then
        log "Found file with UUID: $UUID"
        log "Removing files..."
        ssh_cmd "rm -rf ${REMARKABLE_DIR}/${UUID}*"
        log "Files removed. Restarting xochitl..."
        manage_xochitl restart
        log "Done"
    else
        log "File not found on reMarkable"
    fi
}

cleanup_remarkable() {
    local SEARCH_PATTERNS="$1"
    if [ -z "$SEARCH_PATTERNS" ]; then
        echo "Usage: $0 --purge-except \"pattern1|pattern2\""
        echo "Example: $0 --purge-except \"Quick sheets|Notebook tutorial\""
        echo "WARNING: This will remove ALL files that don't match the patterns!"
        exit 1
    fi

    # validate pattern format
    if [[ ! "$SEARCH_PATTERNS" =~ .*\|.* ]]; then
        echo "ERROR: Pattern must contain at least one '|' separator"
        echo "Example: \"pattern1|pattern2\""
        exit 1
    fi

    echo "WARNING: This will remove ALL files that don't match: $SEARCH_PATTERNS"
    echo "Are you absolutely sure you want to continue? (yes/NO)"
    read -r response
    if [[ ! "$response" == "yes" ]]; then
        echo "Aborting cleanup"
        exit 1
    fi

    manage_xochitl stop

    local PRESERVE_UUIDS=$(ssh $REMARKABLE_HOST "grep -l -E \"$SEARCH_PATTERNS\" ${REMARKABLE_DIR}/*.metadata" |
        xargs basename -a 2>/dev/null |
        cut -d. -f1 |
        tr '\n' ' ')

    if [ -z "$PRESERVE_UUIDS" ]; then
        echo "ERROR: No matching notebooks found. Aborting to prevent data loss."
        manage_xochitl start
        exit 1
    fi

    echo "Found notebooks to preserve with UUIDs: $PRESERVE_UUIDS"
    echo "Continue with removal of all other files? (yes/NO)"
    read -r response
    if [[ ! "$response" == "yes" ]]; then
        echo "Aborting cleanup"
        manage_xochitl start
        exit 1
    fi

    ssh $REMARKABLE_HOST "cd $REMARKABLE_DIR && \
        for f in *; do \
            base=\${f%%.*}; \
            if [[ ! \" $PRESERVE_UUIDS \" =~ \" \$base \" ]]; then \
                rm -rf \$f; \
            fi; \
        done"

    manage_xochitl start
    echo "Cleanup complete!"
}

test_remarkable_connection() {
    if ssh -q "$REMARKABLE_HOST" exit 2>/dev/null; then
        return 0
    fi
    return 1
}

main() {
    local restart_xochitl=true
    local book_dir=""

    # args
    while [[ $# -gt 0 ]]; do
        case $1 in
        --purge-except)
            cleanup_remarkable "$2"
            exit $?
            ;;
        --remove)
            remove_file "$2"
            exit $?
            ;;
        -r | --restart)
            restart_xochitl=true
            shift
            ;;
        --no-restart)
            restart_xochitl=false
            shift
            ;;
        -q | --quiet)
            quiet=true
            shift
            ;;
        -h | --help)
            show_usage
            ;;
        *)
            book_dir="$1"
            break
            ;;
        esac
    done

    [ -z "$book_dir" ] && show_usage

    # check connection
    if ! test_remarkable_connection; then
        echo "Cannot connect to reMarkable tablet via USB ($REMARKABLE_USB) or WiFi ($REMARKABLE_WIFI)"
        exit 1
    fi

    # stop xochitl before transfer
    manage_xochitl stop

    # create temp dir
    local tmpdir=$(create_temp_dir)

    # process files
    find "$book_dir" -type f \( -name "*.pdf" -o -name "*.epub" \) | while read -r file; do
        transfer_file "$file" "$tmpdir"
    done

    # restart xochitl if requested
    if [ "$restart_xochitl" = true ]; then
        log "Restarting xochitl..."
        manage_xochitl restart
    fi
}

main "$@"
