#!/bin/bash

CONFIG_FILE="./config.conf"
if [[ ! -f "$CONFIG_FILE" ]]
then
    echo "Fisierul de configurare nu a fost gasit!"
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
    basename "$1" | sed 's|/|_|g'
}


MODE="$1"


if [[ "$MODE" == "-r" ]]
then
    RESTORE_MODE="$2"

    if [[ "$RESTORE_MODE" == "-a" ]]
    then
        echo "                    MOD RESTAURARE AUTOMAT"
        SOURCE_DIRS="$DEFAULT_SOURCE_DIRS"
    elif [[ "$RESTORE_MODE" == "-i" ]]
    then
        echo "                    MOD RESTAURARE INTERACTIV"
        read -rp "Introduceti directoarele sursa pentru restaurare (spatiu intre ele): " SOURCE_DIRS
    else
        echo "Utilizare: $0 -r -a (sau -r -i)"
        exit 1
    fi

    echo "Fisiere de backup disponibile in $DEFAULT_BACKUP_DIR:"
    backup_files=("$DEFAULT_BACKUP_DIR"/backup_*.tar*)

    if [[ ${#backup_files[@]} -eq 0 ]]
    then
        echo " -> Nu exista fisiere de backup disponibile!"
        exit 1
    fi

    for i in "${!backup_files[@]}"
    do
        echo "$((i+1))) ${backup_files[$i]}"
    done

    read -rp "Alege numarul fisierului de restaurat: " selection

    if ! echo "$selection" | egrep -q '^[0-9]+$' || (( selection < 1 || selection > ${#backup_files[@]} ))
    then
        echo "-> Selectie invalida."
        exit 1
    fi

    BACKUP_FILE="${backup_files[$((selection-1))]}"

    if [[ "$ENCRYPT" == "yes" ]]
    then
        echo " -> Backup-ul este criptat. Se decripteaza..."
        DECRYPTED_FILE=$(mktemp)
        openssl enc -d -aes-256-cbc -in "$BACKUP_FILE" -out "$DECRYPTED_FILE" -pass pass:"$PASSWORD"
        if [[ $? -ne 0 ]]
        then
            echo "-> Eroare la decriptare! Parola gresita sau fisier corupt."
            rm -f "$DECRYPTED_FILE"
            exit 1
        fi
        BACKUP_FILE="$DECRYPTED_FILE"
    fi

    TMP_EXTRACT_DIR=$(mktemp -d)
    tar -xf "$BACKUP_FILE" -C "$TMP_EXTRACT_DIR"

    for dir in $SOURCE_DIRS
    do
        echo "Restaurare pentru: $dir"
        escaped=$(escape_path "$dir")
        META_FILE="$DEFAULT_BACKUP_DIR/metadata_${escaped}.db"

        if [[ ! -f "$META_FILE" ]]
        then
            echo " -> Nu exista metadate pentru $dir. Se sare peste."
            continue
        fi

        while IFS='|' read -r path hash meta
        do
            full_tmp_path="$TMP_EXTRACT_DIR/$path"
            original_path="/$path"

            filename=$(basename "$original_path")
            dirname=$(dirname "$original_path")

            base="${filename%.*}"
            ext="${filename##*.}"

            
            if [[ "$base" == *"_restore" ]]
            then
                restore_name="${filename}"
            else
                if [[ "$base" == "$ext" ]]
                then
                    restore_name="${filename}_restore"
                else
                    restore_name="${base}_restore.${ext}"
                fi
            fi

            restore_path="$dirname/$restore_name"

            if [[ -f "$full_tmp_path" ]]
            then
                if [[ -f "$restore_path" ]]
                then
                    echo " -> Fisier deja restaurat: $restore_path (se omite)"
                else
                    mkdir -p "$dirname"
                    cp "$full_tmp_path" "$restore_path"
                    echo " -> Restaurat: $restore_path"
                fi
            fi
        done < "$META_FILE"
    done

    rm -rf "$TMP_EXTRACT_DIR"
    echo " -> Restaurare completa!"
    exit 0
fi

timestamp=$(date +"%Y%m%d_%H%M%S")

if [[ "$MODE" == "-a" ]]
then
    echo " "
    echo "				MOD AUTOMAT"
    echo " "
    SOURCE_DIRS="$DEFAULT_SOURCE_DIRS"
    BACKUP_DIR="$DEFAULT_BACKUP_DIR"

elif [[ "$MODE" == "-i" ]]
then
    echo " "
    echo "				MOD INTERACTIV"
    echo " "
    read -rp "Introduceti directoarele sursa (separate prin spatiu): " SOURCE_DIRS
    read -rp "Introduceti directorul de backup: " BACKUP_DIR
    read -rp "Introduceti numele fisierului de backup (Enter pentru auto): " USER_ARCHIVE_NAME
else
    echo "Utilizare: $0 -a sau -i sau -r -a/-i"
    exit 1
fi

escaped_names=""
for dir in $SOURCE_DIRS
do
    escaped=$(escape_path "$dir")
    escaped_names+="${escaped}_"
done
escaped_names=${escaped_names%_}
ARCHIVE_NAME="backup_${escaped_names}_${timestamp}.tar"

if [[ -n "$USER_ARCHIVE_NAME" ]]
then
    ARCHIVE_NAME="$USER_ARCHIVE_NAME"
fi

ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_NAME"

mkdir -p "$BACKUP_DIR"
TMP_DIR=$(mktemp -d)
FILES=()

for dir in $SOURCE_DIRS
do
    escaped=$(escape_path "$dir")
    META_PREV="$BACKUP_DIR/metadata_${escaped}.db"
    META_NEW="$TMP_DIR/metadata_${escaped}.db"
    declare -A old_data=()

    echo "Analizez directorul: $dir"
    echo " "

    if [[ -f "$META_PREV" ]]
    then
        echo "> Metadate gasite -> Se va face backup incremental pentru $dir"
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

