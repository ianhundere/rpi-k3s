#!/bin/bash

# default config
REMARKABLE_HOST=${REMARKABLE_HOST:-"remarkable"}
REMARKABLE_DIR=${REMARKABLE_DIR:-"/home/root/.local/share/remarkable/xochitl"}
OBSIDIAN_VAULT="$HOME/notes"
TEMP_DIR=$(mktemp -d)

# cleanup
trap "rm -rf $TEMP_DIR" EXIT

# helper func for SSH commands
ssh_cmd() {
    ssh "$REMARKABLE_HOST" "$@"
}

# get pdf files from remarkable
get_remarkable_files() {
    ssh_cmd "cd $REMARKABLE_DIR && \
        for f in *.metadata; do \
            uuid=\${f%.metadata}; \
            if [ -f \"\$uuid.pdf\" ]; then \
                name=\$(grep -o '\"visibleName\": \"[^\"]*\"' \"\$f\" | cut -d'\"' -f4); \
                echo \"\$uuid|\$name\"; \
            fi; \
        done"
}

# convert pdf to markdown using pdftotext
convert_to_markdown() {
    local pdf="$1"
    local md="$2"

    # check if file exists
    if [ ! -f "$pdf" ]; then
        echo "Error: PDF file not found: $pdf"
        return 1
    fi

    echo "Converting $pdf using pdftotext..."
    if pdftotext "$pdf" - >"$md" 2>/dev/null; then
        sed -i 's/^#/##/' "$md"
        return 0
    else
        echo "pdftotext conversion failed"
        return 1
    fi
}

# Add connection test function
test_remarkable_connection() {
    if ssh -q "$REMARKABLE_HOST" exit 2>/dev/null; then
        return 0
    fi
    return 1
}

show_usage() {
    echo "Usage: $(basename "$0") [OPTIONS]"
    echo
    echo "Download PDFs from reMarkable tablet and convert them to markdown in Obsidian vault."
    echo
    echo "Options:"
    echo "  -h, --help    Show this help message"
    echo
    echo "The script will:"
    echo "  1. Connect to reMarkable tablet"
    echo "  2. Download all PDF files"
    echo "  3. Convert them to markdown"
    echo "  4. Save them to ~/notes/Inbox/"
    exit 1
}

main() {
    echo "Checking connection to reMarkable..."
    if ! test_remarkable_connection; then
        echo "Cannot connect to reMarkable tablet"
        exit 1
    fi

    echo "Connected to reMarkable at $REMARKABLE_HOST"
    echo "Fetching files..."

    # create inbox dir if it doesn't exist
    mkdir -p "$OBSIDIAN_VAULT/Inbox"

    # process files
    while IFS='|' read -r uuid name; do
        echo "Processing: $name"

        # skip if file exists
        if [ -f "$OBSIDIAN_VAULT/Inbox/$name.md" ]; then
            echo "Skipping $name (already exists)"
            continue
        fi

        if ! scp "$REMARKABLE_HOST:$REMARKABLE_DIR/$uuid.pdf" "$TEMP_DIR/${name// /_}.pdf"; then
            echo "Failed to download: $name"
            continue
        fi

        convert_to_markdown "$TEMP_DIR/${name// /_}.pdf" "$OBSIDIAN_VAULT/Inbox/${name// /_}.md"

        if [ $? -eq 0 ]; then
            echo "Successfully converted: $name"

            sed -i "1i---\ntitle: $name\nsource: remarkable\ndate: $(date +%Y-%m-%d)\n---\n\n" "$OBSIDIAN_VAULT/Inbox/$name.md"
        else
            echo "Failed to convert: $name"
        fi
    done < <(get_remarkable_files)

    echo "Done! Check your Obsidian Inbox folder for new notes."
}

# help check
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_usage
fi

main "$@"
