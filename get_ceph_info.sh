#!/bin/bash

# get_ceph_info.sh
# Script to collect comprehensive information about a Ceph cluster
# Output: ceph-mapping.md - A markdown file with detailed Ceph cluster information

# Debug mode - uncomment to enable
#set -x

# Enable error handling while still continuing execution
# No set -e to allow the script to continue on errors
set +e

# Function to log messages
log_debug() {
    echo "[DEBUG] $1" >&2
}

log_error() {
    echo "[ERROR] $1" >&2
}

echo "Collecting Ceph cluster information..."

# Check for required commands
for cmd in ceph ceph-volume lsblk; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: Required command '$cmd' not found"
        echo "Please install the missing package and try again"
        exit 1
    fi
done

# Create a flag to track if jq is available
JQ_AVAILABLE=0
if command -v jq &> /dev/null; then
    JQ_AVAILABLE=1
    log_debug "jq is available for JSON parsing"
else
    log_debug "jq not found, will use alternative parsing methods"
fi

# Create a flag to track if bc is available
BC_AVAILABLE=0
if command -v bc &> /dev/null; then
    BC_AVAILABLE=1
    log_debug "bc is available for calculations"
else
    log_debug "bc not found, will use alternative calculation methods"
fi

# Get hostname for output file and sanitize it
HOST_NAME=$(hostname | tr -cd '[:alnum:]._-')
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_FILE="ceph-details-output-${HOST_NAME}-${TIMESTAMP}.md"

# Initialize the markdown file
cat > ${OUTPUT_FILE} << EOF
# Ceph Cluster Mapping

*Generated on: $(date)*
*Server: ${HOST_NAME}*

## Notes and Legend
- **HDD/SSD**: Indicates the storage device type for each OSD
- **DB Device**: BlueStore's internal metadata database location
- **WAL Device**: BlueStore's write-ahead log location
- **'Colocated'**: Means the DB/WAL is on the same device as the OSD data

## Cluster Overview

EOF

# Get cluster status
echo "Collecting cluster status..."
echo "### Cluster Status" >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
sudo ceph status >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
echo "" >> ${OUTPUT_FILE}

# Get Ceph version
echo "### Ceph Version" >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
sudo ceph version >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
echo "" >> ${OUTPUT_FILE}

# Get cluster health
echo "Collecting health information..."
echo "### Cluster Health" >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
sudo ceph health detail >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
echo "" >> ${OUTPUT_FILE}

# Get OSD tree
echo "Collecting OSD information..."
echo "## OSD Information" >> ${OUTPUT_FILE}
echo "### OSD Tree" >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
sudo ceph osd tree >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
echo "" >> ${OUTPUT_FILE}

# Get OSD df
echo "### OSD Storage Utilization" >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
sudo ceph osd df >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
echo "" >> ${OUTPUT_FILE}

# Get list of OSDs that are local to this server
echo "Identifying local OSDs..."
local_osds=""

# Method 1: Check local OSD directories
if [[ -d "/var/lib/ceph/osd/" ]]; then
    for osd_dir in /var/lib/ceph/osd/ceph-*; do
        if [[ -d "$osd_dir" ]]; then
            osd_id=$(basename "$osd_dir" | sed 's/ceph-//')
            local_osds="$local_osds $osd_id"
            log_debug "Found local OSD directory: $osd_dir for OSD $osd_id"
        fi
    done
fi

# Method 2: Use ceph-volume to list local OSDs (as backup)
if [[ -z "$local_osds" ]]; then
    if command -v ceph-volume &> /dev/null; then
        cv_output=$(sudo ceph-volume lvm list 2>/dev/null)
        if [[ $? -eq 0 && ! -z "$cv_output" ]]; then
            while read -r line; do
                if [[ $line =~ osd\.([0-9]+) ]]; then
                    osd_id="${BASH_REMATCH[1]}"
                    local_osds="$local_osds $osd_id"
                    log_debug "Found local OSD via ceph-volume: $osd_id"
                fi
            done < <(echo "$cv_output" | grep -E "====.osd\.[0-9]+.====")
        fi
    fi
fi

# If we still don't have any local OSDs, log an error
if [[ -z "$local_osds" ]]; then
    log_error "Failed to identify any local OSDs. Continuing with other sections..."
    echo "Error: Failed to identify any local OSDs. This section will be incomplete." >> ${OUTPUT_FILE}
else
    log_debug "Found $(echo $local_osds | wc -w) local OSDs: $local_osds"
    echo "### Local OSDs" >> ${OUTPUT_FILE}
    echo "This server hosts the following OSDs: $(echo $local_osds | tr ' ' ',')" >> ${OUTPUT_FILE}
    echo "" >> ${OUTPUT_FILE}
fi

# Function to parse the ceph-volume lvm list output for local OSDs only
parse_ceph_volume_output() {
    local osd_info
    
    echo "| OSD ID | Block Device | Device Path | Type | DB Device | WAL Device |" >> ${OUTPUT_FILE}
    echo "|:------:|:------------:|:------------:|:----:|:---------:|:----------:|" >> ${OUTPUT_FILE}
    
    for osd_id in $local_osds; do
        # Get OSD info using ceph-volume
        osd_info=$(sudo ceph-volume lvm list "$osd_id" 2>/dev/null)
        if [[ $? -eq 0 && ! -z "$osd_info" ]]; then
            # Initialize variables
            main_device="Unknown"
            block_path="Unknown"
            device_type="Unknown"
            db_device="Colocated"
            wal_device="Colocated with DB"
            
            # Extract devices line which contains the actual physical device
            devices_line=$(echo "$osd_info" | grep -P "^ +devices +")
            if [[ ! -z "$devices_line" ]]; then
                main_device=$(echo "$devices_line" | awk '{print $NF}')
                
                # Check if device exists and determine its type
                if [[ -e "$main_device" ]]; then
                    # Get base device name
                    base_name=$(basename "$main_device")
                    
                    # Check rotational flag (1=HDD, 0=SSD)
                    if [[ -e "/sys/block/$base_name/queue/rotational" ]]; then
                        rotational=$(cat "/sys/block/$base_name/queue/rotational" 2>/dev/null)
                        if [[ "$rotational" == "1" ]]; then
                            device_type="HDD"
                        else
                            device_type="SSD"
                        fi
                    else
                        # Try using lsblk
                        rotational=$(sudo lsblk -d -o NAME,ROTA | grep "$base_name" | awk '{print $2}')
                        if [[ "$rotational" == "1" ]]; then
                            device_type="HDD"
                        elif [[ "$rotational" == "0" ]]; then
                            device_type="SSD"
                        fi
                    fi
                fi
            fi
            
            # Extract block device path
            block_line=$(echo "$osd_info" | grep -A 1 "\[block\]" | grep "block device" | head -1)
            if [[ ! -z "$block_line" ]]; then
                block_path=$(echo "$block_line" | awk '{print $NF}')
            fi
            
            # Extract DB device information
            db_section=$(echo "$osd_info" | grep -A 20 "\[db\]")
            if [[ ! -z "$db_section" ]]; then
                db_line=$(echo "$db_section" | grep "db device" | head -1)
                if [[ ! -z "$db_line" ]]; then
                    db_temp=$(echo "$db_line" | awk '{print $NF}')
                    if [[ "$db_temp" != "None" && "$db_temp" != "null" ]]; then
                        db_device="$db_temp"
                    fi
                fi
                
                # Also try to extract DB device from devices line in DB section
                db_devices_line=$(echo "$db_section" | grep -P "^ +devices +")
                if [[ ! -z "$db_devices_line" ]]; then
                    db_phys_device=$(echo "$db_devices_line" | awk '{print $NF}')
                    if [[ ! -z "$db_phys_device" ]]; then
                        db_device="$db_device (on $db_phys_device)"
                    fi
                fi
            fi
            
            # Extract WAL device information
            wal_section=$(echo "$osd_info" | grep -A 20 "\[wal\]")
            if [[ ! -z "$wal_section" ]]; then
                wal_line=$(echo "$wal_section" | grep "wal device" | head -1)
                if [[ ! -z "$wal_line" ]]; then
                    wal_temp=$(echo "$wal_line" | awk '{print $NF}')
                    if [[ "$wal_temp" != "None" && "$wal_temp" != "null" ]]; then
                        wal_device="$wal_temp"
                    fi
                fi
                
                # Also try to extract WAL device from devices line in WAL section
                wal_devices_line=$(echo "$wal_section" | grep -P "^ +devices +")
                if [[ ! -z "$wal_devices_line" ]]; then
                    wal_phys_device=$(echo "$wal_devices_line" | awk '{print $NF}')
                    if [[ ! -z "$wal_phys_device" ]]; then
                        wal_device="$wal_device (on $wal_phys_device)"
                    fi
                fi
            fi
            
            echo "| $osd_id | $block_path | $main_device | $device_type | $db_device | $wal_device |" >> ${OUTPUT_FILE}
        else
            echo "| $osd_id | Information not available | | | | |" >> ${OUTPUT_FILE}
        fi
    done
}

# Get Disk Types (HDD/SSD) and device information
echo "Collecting disk type information..."
echo "## Storage Device Information" >> ${OUTPUT_FILE}
echo "### OSD to Device Mapping from ceph-volume" >> ${OUTPUT_FILE}
echo "" >> ${OUTPUT_FILE}

# Use the function to parse ceph-volume output for local OSDs
parse_ceph_volume_output

echo "" >> ${OUTPUT_FILE}

# Get streamlined OSD metadata for local OSDs only
echo "### OSD Metadata (Streamlined)" >> ${OUTPUT_FILE}
echo "| OSD ID | Size | Data Path | Device Path | Partition Path | DB Path | WAL Path |" >> ${OUTPUT_FILE}
echo "|:------:|:----:|:---------:|:-----------:|:--------------:|:-------:|:--------:|" >> ${OUTPUT_FILE}

for osd_id in $local_osds; do
    # Get metadata for this OSD
    metadata=$(sudo ceph osd metadata $osd_id 2>/dev/null)
    log_debug "Processing metadata for OSD $osd_id"
    
    # Initialize variables
    size="Unknown"
    data_path="Unknown"
    device_path="Unknown"
    partition_path="Unknown"
    db_path="N/A"
    wal_path="N/A"
    
    if [[ ! -z "$metadata" ]]; then
        # Try different extraction methods
        
        # Method 1: Using grep and cut
        size_raw=$(echo "$metadata" | grep -o '"bluestore_bdev_size":[^,}]*' | cut -d':' -f2 | tr -d '"' | tr -d ' ' 2>/dev/null)
        if [[ ! -z "$size_raw" ]]; then
            # Convert size from bytes to GB if not empty
            if [[ $BC_AVAILABLE -eq 1 ]]; then
                size_gb=$(echo "scale=2; $size_raw / 1024 / 1024 / 1024" | bc -l 2>/dev/null)
                if [[ ! -z "$size_gb" ]]; then
                    size="${size_gb}GB"
                else
                    size="${size_raw} bytes"
                fi
            else
                size="${size_raw} bytes"
            fi
        fi
        
        # Extract paths with more robust patterns
        data_path=$(echo "$metadata" | grep -o '"osd_data":[^,}]*' | cut -d':' -f2 | tr -d '"' | tr -d ' ' 2>/dev/null)
        device_path=$(echo "$metadata" | grep -o '"device_paths":[^,}]*' | cut -d':' -f2 | tr -d '"' | tr -d ' ' 2>/dev/null)
        partition_path=$(echo "$metadata" | grep -o '"bluestore_bdev_partition_path":[^,}]*' | cut -d':' -f2 | tr -d '"' | tr -d ' ' 2>/dev/null)
        db_path=$(echo "$metadata" | grep -o '"bluefs_db_partition_path":[^,}]*' | cut -d':' -f2 | tr -d '"' | tr -d ' ' 2>/dev/null)
        wal_path=$(echo "$metadata" | grep -o '"bluefs_wal_partition_path":[^,}]*' | cut -d':' -f2 | tr -d '"' | tr -d ' ' 2>/dev/null)
        
        # Method 2: Try with alternative pattern if first failed
        if [[ -z "$data_path" || "$data_path" == "Unknown" ]]; then
            data_path=$(echo "$metadata" | grep "osd_data" | head -1 | sed 's/.*"osd_data": *"\([^"]*\)".*/\1/' 2>/dev/null)
        fi
        
        # Alternative methods for other fields
        if [[ -z "$device_path" || "$device_path" == "Unknown" ]]; then
            device_path=$(echo "$metadata" | grep "device_paths" | head -1 | sed 's/.*"device_paths": *"\([^"]*\)".*/\1/' 2>/dev/null)
        fi
        
        if [[ -z "$partition_path" || "$partition_path" == "Unknown" ]]; then
            partition_path=$(echo "$metadata" | grep "bluestore_bdev_partition_path" | head -1 | sed 's/.*"bluestore_bdev_partition_path": *"\([^"]*\)".*/\1/' 2>/dev/null)
        fi
        
        # Check and fix values
        if [[ -z "$data_path" ]]; then
            data_path="Unknown"
        fi
        
        if [[ -z "$device_path" ]]; then
            device_path="Unknown"
        fi
        
        if [[ -z "$partition_path" ]]; then
            partition_path="Unknown"
        fi
        
        if [[ -z "$db_path" ]]; then
            db_path="N/A"
        elif [[ "$db_path" == "null" ]]; then
            db_path="N/A"
        fi
        
        if [[ -z "$wal_path" ]]; then
            wal_path="N/A"
        elif [[ "$wal_path" == "null" ]]; then
            wal_path="N/A"
        fi
    fi
    
    # Method 3: Try using ceph-volume for some details
    if [[ "$data_path" == "Unknown" ]]; then
        osd_dir="/var/lib/ceph/osd/ceph-$osd_id"
        if [[ -d "$osd_dir" ]]; then
            data_path="$osd_dir"
        fi
    fi
    
    if [[ "$device_path" == "Unknown" || "$partition_path" == "Unknown" ]]; then
        cv_info=$(sudo ceph-volume lvm list $osd_id 2>/dev/null)
        if [[ $? -eq 0 && ! -z "$cv_info" ]]; then
            if [[ "$device_path" == "Unknown" ]]; then
                device_path=$(echo "$cv_info" | grep -P "^ +devices" | head -1 | awk '{print $NF}' 2>/dev/null)
            fi
            
            if [[ "$partition_path" == "Unknown" ]]; then
                partition_path=$(echo "$cv_info" | grep "block device" | head -1 | awk '{print $NF}' 2>/dev/null)
            fi
        fi
    fi
    
    # Output to the table
    echo "| $osd_id | $size | $data_path | $device_path | $partition_path | $db_path | $wal_path |" >> ${OUTPUT_FILE}
    log_debug "Added OSD $osd_id metadata to table"
done

echo "" >> ${OUTPUT_FILE}

# Get detailed disk information for local OSDs
echo "### Detailed Disk Information" >> ${OUTPUT_FILE}
echo "" >> ${OUTPUT_FILE}

echo "| OSD ID | Device Path | Type | Size | Model | DB Device | DB Size | WAL Device | WAL Size |" >> ${OUTPUT_FILE}
echo "|:------:|:-----------:|:----:|:----:|:-----:|:---------:|:-------:|:----------:|:--------:|" >> ${OUTPUT_FILE}

# Track progress and display percentage
total_osds=$(echo $local_osds | wc -w)
processed=0

echo "Processing $total_osds local OSDs..."
for osd_id in $local_osds; do
    # Calculate and display progress
    processed=$((processed+1))
    percent=$((processed*100/total_osds))
    echo -ne "Processing OSD $osd_id... ($percent% complete)\r"
    
    # Initialize variables with default values
    osd_device="Unknown"
    device_type="Unknown"
    size="Unknown"
    model="Unknown"
    db_device="Colocated"
    db_size="N/A"
    wal_device="Colocated with DB"
    wal_size="N/A"
    
    # Get detailed OSD info using ceph-volume lvm list
    osd_info=$(sudo ceph-volume lvm list "$osd_id" 2>/dev/null)
    if [[ $? -eq 0 && ! -z "$osd_info" ]]; then
        log_debug "Processing ceph-volume output for OSD $osd_id"
        
        # Extract physical device path from the devices line
        block_section=$(echo "$osd_info" | grep -A 20 "\[block\]")
        devices_line=$(echo "$block_section" | grep -P "^ +devices +")
        if [[ ! -z "$devices_line" ]]; then
            osd_device=$(echo "$devices_line" | awk '{print $NF}')
            log_debug "Found device path for OSD $osd_id: $osd_device"
            
            # Get device properties if it exists
            if [[ -e "$osd_device" ]]; then
                base_name=$(basename "$osd_device")
                log_debug "Base device name: $base_name"
                
                # Get device type (HDD/SSD)
                if [[ -e "/sys/block/$base_name/queue/rotational" ]]; then
                    rotational=$(cat "/sys/block/$base_name/queue/rotational" 2>/dev/null)
                    if [[ "$rotational" == "1" ]]; then
                        device_type="HDD"
                    else
                        device_type="SSD"
                    fi
                else
                    # Try lsblk as fallback
                    rotational=$(sudo lsblk -d -o NAME,ROTA | grep "$base_name" | awk '{print $2}')
                    if [[ "$rotational" == "1" ]]; then
                        device_type="HDD"
                    elif [[ "$rotational" == "0" ]]; then
                        device_type="SSD"
                    fi
                fi
                
                # Get size and model info using lsblk
                size=$(sudo lsblk -d -n -o SIZE "$osd_device" 2>/dev/null || echo "Unknown")
                model=$(sudo lsblk -d -n -o MODEL "$osd_device" 2>/dev/null || echo "Unknown")
                
                # Trim whitespace
                size=$(echo "$size" | xargs)
                model=$(echo "$model" | xargs)
                
                if [[ -z "$model" || "$model" == "Unknown" ]]; then
                    # Try to get model from /sys if available
                    if [[ -e "/sys/block/$base_name/device/model" ]]; then
                        model=$(cat "/sys/block/$base_name/device/model" 2>/dev/null | xargs)
                    fi
                fi
            fi
        else
            # Try to find device from block path section
            block_device_line=$(echo "$block_section" | grep "block device" | head -1)
            if [[ ! -z "$block_device_line" ]]; then
                block_path=$(echo "$block_device_line" | awk '{print $NF}')
                log_debug "Found block path: $block_path"
                
                # Extract the underlying physical device using lvs command
                if [[ "$block_path" == "/dev/ceph"* || "$block_path" == "/dev/mapper"* ]]; then
                    lv_name=$(basename "$block_path")
                    phys_devs=$(sudo lvs --noheadings -o devices "$lv_name" 2>/dev/null | sed 's/(.*)//g' | tr -d ' ' || echo "Unknown")
                    if [[ ! -z "$phys_devs" && "$phys_devs" != "Unknown" ]]; then
                        osd_device=$(echo "$phys_devs" | cut -d',' -f1)
                        log_debug "Resolved block device to physical device: $osd_device"
                    fi
                fi
            fi
        fi
        
        # Get DB device info
        db_section=$(echo "$osd_info" | grep -A 20 "\[db\]")
        if [[ ! -z "$db_section" ]]; then
            db_device_line=$(echo "$db_section" | grep "db device" | head -1)
            db_devices_line=$(echo "$db_section" | grep -P "^ +devices +" | head -1)
            
            if [[ ! -z "$db_device_line" ]]; then
                db_path=$(echo "$db_device_line" | awk '{print $NF}')
                if [[ "$db_path" != "None" && "$db_path" != "null" ]]; then
                    db_device="$db_path"
                    log_debug "Found DB device path: $db_device"
                    
                    # Try to get DB device size using lsblk
                    if [[ -e "$db_path" ]]; then
                        db_size=$(sudo lsblk -d -n -o SIZE "$db_path" 2>/dev/null || echo "Unknown")
                        db_size=$(echo "$db_size" | xargs)
                    fi
                    
                    # Also extract physical device
                    if [[ ! -z "$db_devices_line" ]]; then
                        db_phys_device=$(echo "$db_devices_line" | awk '{print $NF}')
                        if [[ ! -z "$db_phys_device" ]]; then
                            db_device="$db_device (on $db_phys_device)"
                            log_debug "DB is on physical device: $db_phys_device"
                        fi
                    fi
                fi
            fi
        fi
        
        # Get WAL device info
        wal_section=$(echo "$osd_info" | grep -A 20 "\[wal\]")
        if [[ ! -z "$wal_section" ]]; then
            wal_device_line=$(echo "$wal_section" | grep "wal device" | head -1)
            wal_devices_line=$(echo "$wal_section" | grep -P "^ +devices +" | head -1)
            
            if [[ ! -z "$wal_device_line" ]]; then
                wal_path=$(echo "$wal_device_line" | awk '{print $NF}')
                if [[ "$wal_path" != "None" && "$wal_path" != "null" ]]; then
                    wal_device="$wal_path"
                    log_debug "Found WAL device path: $wal_device"
                    
                    # Try to get WAL device size using lsblk
                    if [[ -e "$wal_path" ]]; then
                        wal_size=$(sudo lsblk -d -n -o SIZE "$wal_path" 2>/dev/null || echo "Unknown")
                        wal_size=$(echo "$wal_size" | xargs)
                    fi
                    
                    # Also extract physical device
                    if [[ ! -z "$wal_devices_line" ]]; then
                        wal_phys_device=$(echo "$wal_devices_line" | awk '{print $NF}')
                        if [[ ! -z "$wal_phys_device" ]]; then
                            wal_device="$wal_device (on $wal_phys_device)"
                            log_debug "WAL is on physical device: $wal_phys_device"
                        fi
                    fi
                fi
            fi
        fi
    else
        # Method 1: Try to get device info from ceph-volume lvm list
        if command -v ceph-volume &> /dev/null; then
            log_debug "Using ceph-volume to get device info for OSD $osd_id"
            # First try JSON format if jq is available
            if [[ $JQ_AVAILABLE -eq 1 ]]; then
                log_debug "Attempting JSON format with jq"
                lvm_info=$(sudo ceph-volume lvm list --format json 2>/dev/null)
                if [[ $? -eq 0 && ! -z "$lvm_info" ]]; then
                    log_debug "Successfully retrieved JSON data from ceph-volume"
                    # Extract information about the OSD
                    osd_device=$(echo "$lvm_info" | jq -r ".[$osd_id].devices[]" 2>/dev/null | head -1)
                    # Try to get DB and WAL device info
                    db_device=$(echo "$lvm_info" | jq -r ".[$osd_id].tags.\"ceph.db_device\"" 2>/dev/null)
                    wal_device=$(echo "$lvm_info" | jq -r ".[$osd_id].tags.\"ceph.wal_device\"" 2>/dev/null)
                    
                    # If DB or WAL are not null or empty, update their values
                    if [[ "$db_device" != "null" && ! -z "$db_device" ]]; then
                        db_size=$(echo "$lvm_info" | jq -r ".[$osd_id].tags.\"ceph.db_size\"" 2>/dev/null)
                        # Convert bytes to human-readable size
                        if [[ "$db_size" != "null" && ! -z "$db_size" && $BC_AVAILABLE -eq 1 ]]; then
                            db_size=$(echo "scale=2; $db_size/1024/1024/1024" | bc -l)"G"
                        fi
                    fi
                    
                    if [[ "$wal_device" != "null" && ! -z "$wal_device" ]]; then
                        wal_size=$(echo "$lvm_info" | jq -r ".[$osd_id].tags.\"ceph.wal_size\"" 2>/dev/null)
                        # Convert bytes to human-readable size
                        if [[ "$wal_size" != "null" && ! -z "$wal_size" && $BC_AVAILABLE -eq 1 ]]; then
                            wal_size=$(echo "scale=2; $wal_size/1024/1024/1024" | bc -l)"G"
                        fi
                    fi
                fi
            else
                # If jq is not available, use the regular format output and parse with grep/sed
                lvm_info=$(sudo ceph-volume lvm list $osd_id 2>/dev/null)
                if [[ $? -eq 0 && ! -z "$lvm_info" ]]; then
                    # Extract device information
                    devices_line=$(echo "$lvm_info" | grep -P "^ +devices +")
                    if [[ ! -z "$devices_line" ]]; then
                        osd_device=$(echo "$devices_line" | awk '{print $NF}')
                    fi
                    
                    # Extract DB device information
                    db_line=$(echo "$lvm_info" | grep -P "^ +db device +")
                    if [[ ! -z "$db_line" ]]; then
                        db_device=$(echo "$db_line" | awk '{print $NF}')
                        if [[ "$db_device" != "None" && "$db_device" != "null" ]]; then
                            # Try to get DB size from lsblk if possible
                            db_base=$(basename "$db_device" | sed 's/[0-9]*$//')
                            db_size=$(sudo lsblk -d -o NAME,SIZE | grep "$db_base" | awk '{print $2}')
                        fi
                    fi
                    
                    # Extract WAL device information
                    wal_line=$(echo "$lvm_info" | grep -P "^ +wal device +")
                    if [[ ! -z "$wal_line" ]]; then
                        wal_device=$(echo "$wal_line" | awk '{print $NF}')
                        if [[ "$wal_device" != "None" && "$wal_device" != "null" ]]; then
                            # Try to get WAL size from lsblk if possible
                            wal_base=$(basename "$wal_device" | sed 's/[0-9]*$//')
                            wal_size=$(sudo lsblk -d -o NAME,SIZE | grep "$
                            wal_base" | awk '{print $2}')
                        fi
                    fi
                fi
            fi
        fi
    fi
    
    # Method 2: If still unknown, try from OSD data directory
    if [[ "$osd_device" == "Unknown" ]]; then
        osd_dir="/var/lib/ceph/osd/ceph-$osd_id"
        if [[ -d "$osd_dir" ]]; then
            # Try to get the device from the mount point
            osd_device=$(sudo findmnt -n -o SOURCE --target "$osd_dir" 2>/dev/null)
            
            # If it's an LVM device, try to get the physical device
            if [[ "$osd_device" == *mapper* ]]; then
                lvm_name=$(basename "$osd_device")
                phys_dev=$(sudo lvs --noheadings -o devices "$lvm_name" 2>/dev/null | sed 's/(.*)//g' | tr -d ' ')
                if [[ ! -z "$phys_dev" ]]; then
                    osd_device=$phys_dev
                fi
            fi
        fi
    fi
    
    # Method 3: Try from OSD metadata as a last resort
    if [[ "$osd_device" == "Unknown" ]]; then
        meta_device=$(sudo ceph osd metadata $osd_id 2>/dev/null | grep -o '"devices":"[^"]*"' | cut -d'"' -f4)
        if [[ ! -z "$meta_device" ]]; then
            # Remove any escaped characters and get the first device
            osd_device=$(echo $meta_device | sed 's/\\//g' | cut -d',' -f1)
        fi
    fi
    
    # If we have a device, get its properties
    if [[ "$osd_device" != "Unknown" ]]; then
        log_debug "Getting properties for device: $osd_device"
        
        # Check if device exists
        if [[ -e "$osd_device" ]]; then
            log_debug "Device exists, extracting information"
            # Get the base device name (strip partition numbers)
            base_device=$(echo "$osd_device" | sed -E 's/p?[0-9]+$//')
            base_name=$(basename "$base_device")
            
            log_debug "Base device: $base_device, base name: $base_name"
            
            # Check if rotational (1=HDD, 0=SSD)
            if [[ -e "/sys/block/$base_name/queue/rotational" ]]; then
                rotational=$(cat "/sys/block/$base_name/queue/rotational" 2>/dev/null)
                log_debug "Rotational value from /sys/block: $rotational"
                if [[ "$rotational" == "1" ]]; then
                    device_type="HDD"
                else
                    device_type="SSD"
                fi
            else
                # Fallback to lsblk
                log_debug "Rotational info not found in /sys/block, trying lsblk"
                rotational=$(sudo lsblk -d -o NAME,ROTA 2>/dev/null | grep "$base_name" | awk '{print $2}' || echo "Unknown")
                log_debug "Rotational value from lsblk: $rotational"
                if [[ "$rotational" == "1" ]]; then
                    device_type="HDD"
                elif [[ "$rotational" == "0" ]]; then
                    device_type="SSD"
                fi
            fi
            
            # Get size
            size=$(sudo lsblk -d -o NAME,SIZE 2>/dev/null | grep "$base_name" | awk '{print $2}' || echo "Unknown")
            log_debug "Size from lsblk: $size"
            
            # Get model
            model=$(sudo lsblk -d -o NAME,MODEL 2>/dev/null | grep "$base_name" | awk '{print $2}' || echo "Unknown")
            if [[ -z "$model" || "$model" == "Unknown" ]]; then
                # Try from /sys
                if [[ -e "/sys/block/$base_name/device/model" ]]; then
                    model=$(cat "/sys/block/$base_name/device/model" 2>/dev/null | tr -d ' ' || echo "Unknown")
                    log_debug "Model from /sys/block: $model"
                fi
            else
                log_debug "Model from lsblk: $model"
            fi
        else
            log_debug "Device $osd_device doesn't exist physically, using available metadata only"
        fi
    fi

    # Get DB device info using multiple methods
    log_debug "Getting DB device info for OSD $osd_id"
    db_path=$(sudo ceph osd metadata $osd_id 2>/dev/null | grep -o '"bluefs_db_partition_path":"[^"]*"' | cut -d'"' -f4)
    if [[ ! -z "$db_path" && "$db_path" != "null" ]]; then
        log_debug "Found DB path: $db_path"
        # Try to get the device from the mount point
        db_device=$(sudo findmnt -n -o SOURCE --target "$db_path" 2>/dev/null)
        if [[ -z "$db_device" ]]; then
            # Try using symlinks
            if [[ -L "$db_path" ]]; then
                db_link=$(readlink -f "$db_path" 2>/dev/null)
                log_debug "DB path is a symlink to: $db_link"
                db_device=$(sudo findmnt -n -o SOURCE --target "$(dirname "$db_link")" 2>/dev/null)
            fi
        fi
        
        if [[ ! -z "$db_device" ]]; then
            log_debug "Found DB device: $db_device"
            db_base=$(basename "$db_device" | sed 's/[0-9]*$//')
            db_size=$(sudo lsblk -d -o NAME,SIZE 2>/dev/null | grep "$db_base" | awk '{print $2}' || echo "Unknown")
            if [[ -z "$db_size" ]]; then
                db_size="Unknown"
                log_debug "Could not determine DB size"
            else
                log_debug "DB size: $db_size"
            fi
        else
            db_device="Colocated"
            db_size="N/A"
            log_debug "DB appears to be colocated with OSD device"
        fi
    fi

    # Get WAL device info (similar to DB device)
    log_debug "Getting WAL device info for OSD $osd_id"
    wal_path=$(sudo ceph osd metadata $osd_id 2>/dev/null | grep -o '"bluefs_wal_partition_path":"[^"]*"' | cut -d'"' -f4)
    if [[ ! -z "$wal_path" && "$wal_path" != "null" ]]; then
        log_debug "Found WAL path: $wal_path"
        wal_device=$(sudo findmnt -n -o SOURCE --target "$wal_path" 2>/dev/null)
        if [[ -z "$wal_device" && -L "$wal_path" ]]; then
            wal_link=$(readlink -f "$wal_path" 2>/dev/null)
            log_debug "WAL path is a symlink to: $wal_link"
            wal_device=$(sudo findmnt -n -o SOURCE --target "$(dirname "$wal_link")" 2>/dev/null)
        fi
        
        if [[ ! -z "$wal_device" ]]; then
            log_debug "Found WAL device: $wal_device"
            wal_base=$(basename "$wal_device" | sed 's/[0-9]*$//')
            wal_size=$(sudo lsblk -d -o NAME,SIZE 2>/dev/null | grep "$wal_base" | awk '{print $2}' || echo "Unknown")
            if [[ -z "$wal_size" ]]; then
                wal_size="Unknown"
                log_debug "Could not determine WAL size"
            else
                log_debug "WAL size: $wal_size"
            fi
        fi
    else
        log_debug "No WAL path found for OSD $osd_id"
    fi

    # Add the row to the table
    log_debug "Adding OSD $osd_id data to the table"
    echo "| $osd_id | $osd_device | $device_type | $size | $model | $db_device | $db_size | $wal_device | $wal_size |" >> ${OUTPUT_FILE}
done

# Clear progress line after completion
echo -ne "                                                \r"
echo "All OSDs processed successfully."

# Get Pool Information
echo "Collecting pool information..."
echo "## Pool Information" >> ${OUTPUT_FILE}
echo "### Pool Usage" >> ${OUTPUT_FILE}
echo "| Pool Name | Size | Used | Available | % Used |" >> ${OUTPUT_FILE}
echo "|:---------:|:----:|:----:|:---------:|:------:|" >> ${OUTPUT_FILE}

# Get pool usage data
pool_data=$(sudo ceph df detail 2>/dev/null)

# Get list of pools
pools=$(sudo ceph osd pool ls)

# For each pool, extract usage information
for pool in $pools; do
    echo "Processing pool $pool..."
    
    # Extract pool statistics - first try with grep
    pool_stats=$(echo "$pool_data" | grep -A 6 "^$pool " 2>/dev/null)
    
    if [[ ! -z "$pool_stats" ]]; then
        # Parse size information
        size=$(echo "$pool_stats" | grep "SIZE" | awk '{print $2}')
        used=$(echo "$pool_stats" | grep "USED" | awk '{print $2}')
        avail=$(echo "$pool_stats" | grep "AVAIL" | awk '{print $2}')
        pcent=$(echo "$pool_stats" | grep "%" | awk '{print $2}')
        
        # Handle older Ceph versions with different output format
        if [[ -z "$size" || -z "$used" || -z "$avail" || -z "$pcent" ]]; then
            size=$(echo "$pool_stats" | awk 'NR==1 {print $3}')
            used=$(echo "$pool_stats" | awk 'NR==1 {print $4}')
            avail=$(echo "$pool_stats" | awk 'NR==1 {print $5}')
            pcent=$(echo "$pool_stats" | awk 'NR==1 {print $6}')
        fi
    
        # Add to the table
        echo "| $pool | $size | $used | $avail | $pcent |" >> ${OUTPUT_FILE}
    else
        # If we couldn't get stats, just add the pool name
        echo "| $pool | N/A | N/A | N/A | N/A |" >> ${OUTPUT_FILE}
    fi
done

echo "" >> ${OUTPUT_FILE}

# PG Information
echo "Collecting PG information..."
echo "## Placement Group Information" >> ${OUTPUT_FILE}
echo "### PG Status" >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
sudo ceph pg stat >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
echo "" >> ${OUTPUT_FILE}

# Add additional section with lsblk information for all devices
echo "## System Storage Overview" >> ${OUTPUT_FILE}
echo "### All Block Devices" >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
sudo lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT,FSTYPE >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
echo "" >> ${OUTPUT_FILE}

echo "### LVM Configuration" >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
sudo pvs >> ${OUTPUT_FILE}
echo "" >> ${OUTPUT_FILE}
sudo vgs >> ${OUTPUT_FILE}
echo "" >> ${OUTPUT_FILE}
sudo lvs >> ${OUTPUT_FILE}
echo '```' >> ${OUTPUT_FILE}
echo "" >> ${OUTPUT_FILE}

# Add a note about how to read the mapping
# Remove the duplicated notes section at the end
echo "Ceph cluster information collected successfully!"
echo "Results saved to ${OUTPUT_FILE}"