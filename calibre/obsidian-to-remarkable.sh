#!/bin/bash

# default config
REMARKABLE_HOST=${REMARKABLE_HOST:-"remarkable"}
REMARKABLE_DIR=${REMARKABLE_DIR:-"/home/root/.local/share/remarkable/xochitl"}
OBSIDIAN_VAULT="$HOME/notes"
TEMP_DIR=$(mktemp -d)

# cleanup on exit
trap "rm -rf $TEMP_DIR" EXIT

# ssh helper
ssh_cmd() {
    ssh "$REMARKABLE_HOST" "$@"
}

convert_to_pdf() {
    local md="$1"
    local pdf="$2"
    local title=$(basename "${md%.md}")
    local ext="${title##*.}"
    local temp_md=$(mktemp)

    echo "Converting $title to PDF..."

    # handle different file types
    case "$ext" in
    yml | yaml)
        # wrap yaml in code fence
        echo '```yaml' >"$temp_md"
        cat "$md" >>"$temp_md"
        echo '```' >>"$temp_md"

        pandoc "$temp_md" \
            -o "$pdf" \
            --pdf-engine=tectonic \
            -V geometry:margin=1in \
            -V documentclass=article \
            -V fontsize=11pt \
            -V fontfamily=sans \
            -V monofont="DejaVu Sans Mono" \
            -V links-as-notes=true \
            -V colorlinks=true \
            --highlight-style=tango \
            -f markdown+fenced_code_blocks \
            -t pdf \
            --wrap=none 2>/dev/null

        rm -f "$temp_md"
        ;;
    conf | ini | config)
        # config files get monospace font
        pandoc "$md" \
            -o "$pdf" \
            --pdf-engine=tectonic \
            -V geometry:margin=1in \
            -V documentclass=article \
            -V fontsize=11pt \
            -V fontfamily=sans \
            -V monofont="DejaVu Sans Mono" \
            -V links-as-notes=true \
            -V colorlinks=true \
            --highlight-style=tango \
            -f markdown -t pdf 2>/dev/null
        ;;
    *)
        # default markdown handling
        pandoc "$md" \
            -o "$pdf" \
            --pdf-engine=tectonic \
            -V geometry:margin=1in \
            -V documentclass=article \
            -V fontsize=11pt \
            -V fontfamily=sans \
            -V mainfont="DejaVu Serif" \
            -V monofont="DejaVu Sans Mono" \
            -V links-as-notes=true \
            -V colorlinks=true \
            --standalone \
            --toc 2>/dev/null
        ;;
    esac
}

upload_to_remarkable() {
    local pdf="$1"
    local title=$(basename "${pdf%.pdf}")
    local uuid=$(uuidgen)

    echo "Uploading $title to reMarkable..."

    # create metadata
    cat >"$TEMP_DIR/$uuid.metadata" <<EOF
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

    # create content file
    cat >"$TEMP_DIR/$uuid.content" <<EOF
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
        "m11": 1, "m12": 0, "m13": 0,
        "m21": 0, "m22": 1, "m23": 0,
        "m31": 0, "m32": 0, "m33": 1
    }
}
EOF

    # copy files to remarkable
    scp "$pdf" "$REMARKABLE_HOST:$REMARKABLE_DIR/$uuid.pdf"
    scp "$TEMP_DIR/$uuid.metadata" "$REMARKABLE_HOST:$REMARKABLE_DIR/"
    scp "$TEMP_DIR/$uuid.content" "$REMARKABLE_HOST:$REMARKABLE_DIR/"

    # create required dirs
    ssh_cmd "mkdir -p $REMARKABLE_DIR/$uuid.thumbnails"
    ssh_cmd "mkdir -p $REMARKABLE_DIR/$uuid.highlights"
    ssh_cmd "mkdir -p $REMARKABLE_DIR/$uuid.cache"

    echo "Successfully uploaded $title"
}

test_remarkable_connection() {
    if ssh -q "$REMARKABLE_HOST" exit 2>/dev/null; then
        return 0
    fi
    return 1
}

show_usage() {
    echo "Usage: $(basename "$0") [OPTIONS] [FILES/DIRECTORIES]"
    echo
    echo "Convert markdown files to PDF and upload them (or upload PDF files directly) to reMarkable tablet."
    echo
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo
    echo "Arguments:"
    echo "  If no arguments provided, processes all .md and .pdf files from ~/notes"
    echo "  Otherwise, processes specified files or directories"
    echo
    echo "Examples:"
    echo "  $(basename "$0")                           # Process all files in ~/notes"
    echo "  $(basename "$0") ~/notes/myfile.md         # Process single markdown file"
    echo "  $(basename "$0") ~/notes/document.pdf      # Upload single PDF file"
    echo "  $(basename "$0") ~/notes/file1.md file2.pdf # Process multiple files"
    echo "  $(basename "$0") ~/documents/              # Process all supported files in directory"
    exit 1
}

main() {
    local files=()

    # get files to process
    if [ $# -gt 0 ]; then
        files=("$@")
    else
        # process all markdown and pdf files in vault
        while IFS= read -r -d '' file; do
            files+=("$file")
        done < <(find "$OBSIDIAN_VAULT" \( -name "*.md" -o -name "*.pdf" \) -print0)
    fi

    # check remarkable connection
    if ! test_remarkable_connection; then
        echo "Cannot connect to reMarkable tablet"
        exit 1
    fi

    # stop remarkable ui
    ssh_cmd "systemctl stop xochitl"

    for file in "${files[@]}"; do
        title=$(basename "${file%.*}")
        ext="${file##*.}"

        if [ "$ext" = "pdf" ]; then
            # directly upload pdfs
            upload_to_remarkable "$file"
        else
            # convert and upload
            pdf="$TEMP_DIR/${title// /_}.pdf"
            if convert_to_pdf "$file" "$pdf"; then
                upload_to_remarkable "$pdf"
            else
                echo "Failed to convert: $title"
            fi
        fi
    done

    # restart remarkable ui
    ssh_cmd "systemctl restart xochitl"
    sleep 2 # wait for ui to start

    echo "Done! Check your reMarkable tablet."
}

# help check
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_usage
fi

main "$@"
