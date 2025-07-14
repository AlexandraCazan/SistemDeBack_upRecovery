#!/bin/bash

CONFIG_FILE="./config.conf"
if [[ ! -f "$CONFIG_FILE" ]]
then
    echo "Fișierul de configurare nu a fost găsit!"
    exit 1
fi
source "$CONFIG_FILE"

function get_hash {
    sha256sum "$1" | cut -d ' ' -f1
}

function get_metadata {
    local file="$1"
    local acl_hash=$(getfacl --absolute-names --omit-header "$file" 2>/dev/null | sha256sum | cut -d ' ' -f1)
    echo "$(stat --format "%U|%G|%a|%Y" "$file")|$acl_hash"
}

function encrypt_archive {
    local input_file="$1"
    local password="$2"
    openssl enc -aes-256-cbc -salt -in "$input_file" -out "$input_file.enc" -pass pass:"$password"
    rm "$input_file"
    mv "$input_file.enc" "$input_file"
}

function escape_path {
    echo "$1" | sed 's|/|_|g' | sed 's|^_||'
}

MODE="$1"
timestamp=$(date +"%Y%m%d_%H%M%S")
ARCHIVE_NAME="backup_${timestamp}.tar"

if [[ "$MODE" == "-a" ]]
then
    echo "MOD AUTOMAT"
    SOURCE_DIRS="$DEFAULT_SOURCE_DIRS"
    BACKUP_DIR="$DEFAULT_BACKUP_DIR"
    ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_NAME"

elif [[ "$MODE" == "-i" ]]
then
    echo "MOD INTERACTIV"
    read -rp "Introduceti directoarele sursa (separate prin spatiu): " SOURCE_DIRS
    read -rp "Introduceti directorul de backup: " BACKUP_DIR
    read -rp "Introduceti numele fisierului de backup (Enter pentru auto): " USER_ARCHIVE_NAME

    if [[ -n "$USER_ARCHIVE_NAME" ]]
    then
        ARCHIVE_NAME="$USER_ARCHIVE_NAME"
    fi
    ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_NAME"
else
    echo "Utilizare: $0 -a sau -i"
    exit 1
fi

mkdir -p "$BACKUP_DIR"
TMP_DIR=$(mktemp -d)
FILES=()

for dir in $SOURCE_DIRS
do
    escaped=$(escape_path "$dir")
    META_PREV="$BACKUP_DIR/metadata_${escaped}.db"
    META_NEW="$TMP_DIR/metadata_${escaped}.db"
    declare -A old_data=()

    if [[ -f "$META_PREV" ]]
    then
        echo "Backup incremental pentru $dir"
        while IFS='|' read -r path hash meta
        do
            old_data["$path"]="$hash|$meta"
        done < "$META_PREV"
    else
        echo "Backup complet pentru $dir (fără metadate anterioare)"
    fi

    while read -r file
    do
        if [[ ! -f "$file" ]]
        then
        	continue
        fi
        hash=$(get_hash "$file")
        meta=$(get_metadata "$file")
        rel_path=$(realpath --relative-to=/ "$file")
        echo "$rel_path|$hash|$meta" >> "$META_NEW"

        old="${old_data["$rel_path"]}"
        if [[ "$old" != "$hash|$meta" ]]
        then
            FILES+=("/$rel_path")
        fi
    done < <(find "$dir" -type f 2>/dev/null)

    cp "$META_NEW" "$BACKUP_DIR/metadata_${escaped}.db"
done

if [[ ${#FILES[@]} -eq 0 ]]
then
    echo "Nicio modificare detectata. Nu s-a creat un nou backup."
    rm -rf "$TMP_DIR" "$TMP_EXTRACT_DIR" 2>/dev/null
    exit 0
else
    tar -cf "$ARCHIVE_PATH" "${FILES[@]}"
fi

if [[ "$ENCRYPT" == "yes" && -n "$PASSWORD" ]]
then
    encrypt_archive "$ARCHIVE_PATH" "$PASSWORD"
    echo "Backup criptat cu succes!"
fi

sed -i "s|^PREV_BACKUP=.*|PREV_BACKUP=\"$ARCHIVE_PATH\"|" "$CONFIG_FILE"

echo "Backup final salvat în: $ARCHIVE_PATH"
rm -rf "$TMP_DIR"

