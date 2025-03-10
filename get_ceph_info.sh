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

# Initialize the markdown file
cat > ceph-mapping.md << EOF
# Ceph Cluster Mapping

*Generated on: $(date)*

## Cluster Overview

EOF

# Get cluster status
echo "Collecting cluster status..."
echo "### Cluster Status" >> ceph-mapping.md
echo '```' >> ceph-mapping.md
sudo ceph status >> ceph-mapping.md
echo '```' >> ceph-mapping.md
echo "" >> ceph-mapping.md

# Get Ceph version
echo "### Ceph Version" >> ceph-mapping.md
echo '```' >> ceph-mapping.md
sudo ceph version >> ceph-mapping.md
echo '```' >> ceph-mapping.md
echo "" >> ceph-mapping.md

# Get cluster health
echo "Collecting health information..."
echo "### Cluster Health" >> ceph-mapping.md
echo '```' >> ceph-mapping.md
sudo ceph health detail >> ceph-mapping.md
echo '```' >> ceph-mapping.md
echo "" >> ceph-mapping.md

# Get OSD tree
echo "Collecting OSD information..."
echo "## OSD Information" >> ceph-mapping.md
echo "### OSD Tree" >> ceph-mapping.md
echo '```' >> ceph-mapping.md
sudo ceph osd tree >> ceph-mapping.md
echo '```' >> ceph-mapping.md
echo "" >> ceph-mapping.md

# Get OSD df
echo "### OSD Storage Utilization" >> ceph-mapping.md
echo '```' >> ceph-mapping.md
sudo ceph osd df >> ceph-mapping.md
echo '```' >> ceph-mapping.md
echo "" >> ceph-mapping.md

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
    echo "Error: Failed to identify any local OSDs. This section will be incomplete." >> ceph-mapping.md
else
    log_debug "Found $(echo $local_osds | wc -w) local OSDs: $local_osds"
    echo "### Local OSDs" >> ceph-mapping.md
    echo "This server hosts the following OSDs: $(echo $local_osds | tr ' ' ',')" >> ceph-mapping.md
    echo "" >> ceph-mapping.md
fi

# Function to parse the ceph-volume lvm list output for local OSDs only
parse_ceph_volume_output() {
    local osd_info
    
    echo "| OSD ID | Block Device | Device Path | DB Device | WAL Device |" >> ceph-mapping.md
    echo "|--------|-------------|-------------|-----------|------------|" >> ceph-mapping.md
    
    for osd_id in $local_osds; do
        osd_info=$(sudo ceph-volume lvm list "$osd_id" 2>/dev/null)
        if [[ $? -eq 0 && ! -z "$osd_info" ]]; then
            # Extract device information
            main_device=$(echo "$osd_info" | grep -P "^ +devices +")
            if [[ ! -z "$main_device" ]]; then
                main_device=$(echo "$main_device" | awk '{print $NF}')
            else
                main_device="Unknown"
            fi
            
            # Extract block device path
            block_path=$(echo "$osd_info" | grep "block device" | head -1 | awk '{print $NF}')
            if [[ -z "$block_path" ]]; then
                block_path="Unknown"
            fi
            
            # Extract DB device information
            db_device="Colocated"
            db_line=$(echo "$osd_info" | grep -P "^ +db device +")
            if [[ ! -z "$db_line" ]]; then
                db_temp=$(echo "$db_line" | awk '{print $NF}')
                if [[ "$db_temp" != "None" && "$db_temp" != "null" ]]; then
                    db_device="$db_temp"
                fi
            fi
            
            # Extract WAL device information
            wal_device="Colocated with DB"
            wal_line=$(echo "$osd_info" | grep -P "^ +wal device +")
            if [[ ! -z "$wal_line" ]]; then
                wal_temp=$(echo "$wal_line" | awk '{print $NF}')
                if [[ "$wal_temp" != "None" && "$wal_temp" != "null" ]]; then
                    wal_device="$wal_temp"
                fi
            fi
            
            echo "| $osd_id | $block_path | $main_device | $db_device | $wal_device |" >> ceph-mapping.md
        else
            echo "| $osd_id | Information not available | | | |" >> ceph-mapping.md
        fi
    done
}

# Get Disk Types (HDD/SSD) and device information
echo "Collecting disk type information..."
echo "## Storage Device Information" >> ceph-mapping.md
echo "### OSD to Device Mapping from ceph-volume" >> ceph-mapping.md
echo "" >> ceph-mapping.md

# Use the function to parse ceph-volume output for local OSDs
parse_ceph_volume_output

echo "" >> ceph-mapping.md

# Get streamlined OSD metadata for local OSDs only
echo "### OSD Metadata (Streamlined)" >> ceph-mapping.md
echo "| OSD ID | Size | Data Path | Device Path | Partition Path | DB Path | WAL Path |" >> ceph-mapping.md
echo "|--------|------|-----------|-------------|----------------|---------|----------|" >> ceph-mapping.md

for osd_id in $local_osds; do
    # Get metadata for this OSD
    metadata=$(sudo ceph osd metadata $osd_id 2>/dev/null)
    
    # Extract only the information we want
    size=$(echo "$metadata" | grep -o '"bluestore_bdev_size":"[^"]*"' | cut -d'"' -f4)
    # Convert size from bytes to GB if not empty
    if [[ ! -z "$size" && $BC_AVAILABLE -eq 1 ]]; then
        size_gb=$(echo "scale=2; $size / 1024 / 1024 / 1024" | bc -l)
        size="${size_gb}GB"
    fi
    
    data_path=$(echo "$metadata" | grep -o '"osd_data":"[^"]*"' | cut -d'"' -f4)
    device_path=$(echo "$metadata" | grep -o '"device_paths":"[^"]*"' | cut -d'"' -f4)
    partition_path=$(echo "$metadata" | grep -o '"bluestore_bdev_partition_path":"[^"]*"' | cut -d'"' -f4)
    db_path=$(echo "$metadata" | grep -o '"bluefs_db_partition_path":"[^"]*"' | cut -d'"' -f4)
    wal_path=$(echo "$metadata" | grep -o '"bluefs_wal_partition_path":"[^"]*"' | cut -d'"' -f4)
    
    # Output to the table
    echo "| $osd_id | $size | $data_path | $device_path | $partition_path | $db_path | $wal_path |" >> ceph-mapping.md
done

echo "" >> ceph-mapping.md

# Get detailed disk information for local OSDs
echo "### Detailed Disk Information" >> ceph-mapping.md
echo "" >> ceph-mapping.md

echo "| OSD ID | Device Path | Type | Size | Model | DB Device | DB Size | WAL Device | WAL Size |" >> ceph-mapping.md
echo "|--------|-------------|------|------|-------|-----------|---------|------------|----------|" >> ceph-mapping.md

# Track progress
total_osds=$(echo $local_osds | wc -w)
processed=0

for osd_id in $local_osds; do
    echo "Processing OSD $osd_id..."
    log_debug "Beginning processing for OSD $osd_id (Progress: $((++processed))/$total_osds)"
    
    # Initialize variables with default values
    osd_device="Unknown"
    device_type="Unknown"
    size="Unknown"
    model="Unknown"
    db_device="Colocated"
    db_size="N/A"
    wal_device="Colocated with DB"
    wal_size="N/A"
    
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
                        wal_size=$(sudo lsblk -d -o NAME,SIZE | grep "$wal_base" | awk '{print $2}')
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
    echo "| $osd_id | $osd_device | $device_type | $size | $model | $db_device | $db_size | $wal_device | $wal_size |" >> ceph-mapping.md
done

# Get Pool Information
echo "Collecting pool information..."
echo "## Pool Information" >> ceph-mapping.md
echo "### Pool Usage" >> ceph-mapping.md
echo "| Pool Name | Size | Used | Available | % Used |" >> ceph-mapping.md
echo "|-----------|------|------|-----------|--------|" >> ceph-mapping.md

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
        echo "| $pool | $size | $used | $avail | $pcent |" >> ceph-mapping.md
    else
        # If we couldn't get stats, just add the pool name
        echo "| $pool | N/A | N/A | N/A | N/A |" >> ceph-mapping.md
    fi
done

echo "" >> ceph-mapping.md

# PG Information
echo "Collecting PG information..."
echo "## Placement Group Information" >> ceph-mapping.md
echo "### PG Status" >> ceph-mapping.md
echo '```' >> ceph-mapping.md
sudo ceph pg stat >> ceph-mapping.md
echo '```' >> ceph-mapping.md
echo "" >> ceph-mapping.md

# Add additional section with lsblk information for all devices
echo "## System Storage Overview" >> ceph-mapping.md
echo "### All Block Devices" >> ceph-mapping.md
echo '```' >> ceph-mapping.md
sudo lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT,FSTYPE >> ceph-mapping.md
echo '```' >> ceph-mapping.md
echo "" >> ceph-mapping.md

echo "### LVM Configuration" >> ceph-mapping.md
echo '```' >> ceph-mapping.md
sudo pvs >> ceph-mapping.md
echo "" >> ceph-mapping.md
sudo vgs >> ceph-mapping.md
echo "" >> ceph-mapping.md
sudo lvs >> ceph-mapping.md
echo '```' >> ceph-mapping.md
echo "" >> ceph-mapping.md

# Add a note about how to read the mapping
echo "## Notes" >> ceph-mapping.md
echo "- **HDD/SSD**: Indicates the storage device type for each OSD" >> ceph-mapping.md
echo "- **DB Device**: BlueStore's internal metadata database location" >> ceph-mapping.md
echo "- **WAL Device**: BlueStore's write-ahead log location" >> ceph-mapping.md
echo "- **'Colocated'**: Means the DB/WAL is on the same device as the OSD data" >> ceph-mapping.md
echo "" >> ceph-mapping.md

echo "Ceph cluster information collected successfully!"
echo "Results saved to ceph-mapping.md"