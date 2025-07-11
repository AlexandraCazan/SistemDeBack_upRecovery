#!/bin/bash

function get_hash
{
	sha256sum "$1" | cut -d ' ' -f1
}

function get_metadata
{
	local file="$1"
	local acl_hash=$(getfacl --absolute-names --omit-header "$file" 2>/dev/null | sha256sum | cut -d ' ' -f1)
	echo "$(stat --format "%U|%G|%a|%Y" "$file")|$acl_hash"
}

function encrypt_archive
{
	local input_file="$1"
	local password="$2"
	openssl enc -aes-256-cbc -salt -in "$input_file" -out "$input_file.enc" -pass pass:"$password"
	rm "$input_file"
	mv "$input_file.enc" "$input_file"
}


if [[ "$1" == "-c" || "$1" == "--config" ]]; then
    shift
    if [[ $# -eq 0 ]]; then
        echo "Eroare: trebuie să specifici un fișier de configurare sau unul sau mai multe directoare!"
        exit 1
    fi

    if [[ -f "$1" ]]; then
        # E un fișier de configurare valid
        source "$1"
        shift
    else
        # Nu e fișier, deci tratăm tot ce urmează ca directoare
        BACKUP_DIR="$HOME/test_backups"
	PREV_BACKUP="$HOME/test_backups/backup_20250711_120605.tar"
	ENCRYPT="yes"
	PASSWORD="alle2133"
        while [[ $# -gt 0 ]]; do
            if [[ -d "$1" ]]; then
                SOURCE_DIRS="$SOURCE_DIRS $1"
            else
                echo "Eroare: '$1' nu este un director valid!"
                exit 1
            fi
            shift
        done
    fi
else
    echo "Eroare: trebuie să folosești -c urmat de un fișier sau directoare!"
    exit 1
fi

# Validare finală
if [[ -z "$SOURCE_DIRS" ]]; then
    echo "Eroare: Nu au fost specificate directoare!"
    exit 1
fi

mkdir -p "$BACKUP_DIR"
TMP_DIR=$(mktemp -d)
META_NEW="$TMP_DIR/metadata.db"
ARCHIVE_NAME="backup_$(date +'%Y%m%d_%H%M%S').tar"
ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_NAME"

declare -A old_data

if [[ -n "$PREV_BACKUP" && -f "$PREV_BACKUP" ]]
then
	    tar -xf "$PREV_BACKUP" -C "$TMP_DIR" prev_metadata.db || true
	    if [[ -f "$TMP_DIR/prev_metadata.db" ]]
	    then
	    	while IFS='|' read -r path hash meta
	    	do
	    		old_data["$path"]="$hash|$meta"
	    	done < "$TMP_DIR/prev_metadata.db"
	    fi
fi

FILES=()

for dir in $SOURCE_DIRS
do
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

		if [[ "$old" != "$hash|$meta" ]]; then
 			FILES+=("/$rel_path")
		fi

	
	done < <(find "$dir" -type f 2>/dev/null)
done

if [[ ${#FILES[@]} -eq 0 ]]
then
	echo "Nimic nou de salvat. Backup gol."
	touch "$ARCHIVE_PATH"
else
	tar -cf "$ARCHIVE_PATH" "${FILES[@]}"
fi

cp "$META_NEW" "$TMP_DIR/prev_metadata.db"
tar --append --file="$ARCHIVE_PATH" -C "$TMP_DIR" prev_metadata.db

if [[ "$ENCRYPT" == "yes" && -n "$PASSWORD" ]]
then
	    encrypt_archive "$ARCHIVE_PATH" "$PASSWORD"
	    echo "Backup criptat cu succes!"
fi

echo "backup final salvat in:$ARCHIVE_PATH"
rm -rf "$TMP_DIR"
	
