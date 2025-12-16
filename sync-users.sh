#!/bin/bash

# PM Hub to Knock User Sync Script
# This script fetches users from Knock, queries PostgreSQL, and bulk syncs users to Knock

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables from .env file
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

# Check required environment variables
if [ -z "$KNOCK_API_KEY" ]; then
    echo -e "${RED}Error: KNOCK_API_KEY not set in .env file${NC}"
    exit 1
fi

if [ -z "$DB_HOST" ] || [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
    echo -e "${RED}Error: Database credentials not set in .env file${NC}"
    exit 1
fi

# Check for required tools
command -v curl >/dev/null 2>&1 || { echo -e "${RED}Error: curl is required but not installed${NC}"; exit 1; }
command -v psql >/dev/null 2>&1 || { echo -e "${RED}Error: psql is required but not installed${NC}"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo -e "${YELLOW}Warning: jq is recommended for better JSON parsing${NC}"; }

# Set database port (default 5432)
DB_PORT=${DB_PORT:-5432}

# Create logs directory
mkdir -p logs

# Get current date
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DATE_STR=$(date -u +"%Y-%m-%d")

echo -e "${GREEN}=== PM Hub to Knock User Sync ===${NC}\n"

# Step 1: Fetch existing users from Knock API
echo -e "${BLUE}Fetching existing users from Knock API...${NC}"
KNOCK_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $KNOCK_API_KEY" \
    "https://api.knock.app/v1/users")

HTTP_CODE=$(echo "$KNOCK_RESPONSE" | tail -n1)
KNOCK_BODY=$(echo "$KNOCK_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    echo -e "${RED}Error: Failed to fetch Knock users (HTTP $HTTP_CODE)${NC}"
    echo "$KNOCK_BODY"
    exit 1
fi

# Parse Knock users (using jq if available, otherwise basic parsing)
if command -v jq >/dev/null 2>&1; then
    # Use jq for proper JSON parsing
    KNOCK_USERS_JSON=$(echo "$KNOCK_BODY" | jq -r '.entries[] | select(.id != null) | {id: .id, email: (.email // .properties.email // ""), name: (.name // .properties.name // "")}')
    
    # Extract unique user IDs
    KNOCK_USER_IDS=$(echo "$KNOCK_BODY" | jq -r '.entries[] | select(.id != null) | .id' | sort -u)
    
    # Count users
    KNOCK_USER_COUNT=$(echo "$KNOCK_USER_IDS" | wc -l | tr -d ' ')
    
    # Display table
    echo -e "\n${GREEN}Existing Knock Users:${NC}"
    echo "$KNOCK_USERS_JSON" | jq -r '"\(.id)\t\(.email)\t\(.name)"' | column -t -s $'\t'
    
else
    # Basic parsing without jq (less reliable)
    echo -e "${YELLOW}Warning: jq not available, using basic parsing${NC}"
    KNOCK_USER_IDS=$(echo "$KNOCK_BODY" | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | sort -u)
    KNOCK_USER_COUNT=$(echo "$KNOCK_USER_IDS" | grep -c . || echo "0")
fi

echo -e "\n${GREEN}Found $KNOCK_USER_COUNT existing Knock users${NC}"

# Write Knock users to log file
KNOCK_LOG="logs/${DATE_STR}_knock_users.log"
{
    echo "=== $DATE ==="
    echo -e "id\temail\tname"
    if command -v jq >/dev/null 2>&1; then
        echo "$KNOCK_USERS_JSON" | jq -r '"\(.id)\t\(.email)\t\(.name)"'
    else
        # Basic log format without jq
        echo "$KNOCK_BODY" | grep -o '"id":"[^"]*"' | while read -r line; do
            ID=$(echo "$line" | cut -d'"' -f4)
            echo -e "$ID\t\t"
        done
    fi
} > "$KNOCK_LOG"
echo -e "${GREEN}Knock users written to $KNOCK_LOG${NC}"

# Step 2: Build exclusion clause for PostgreSQL query
EXCLUSION_CLAUSE=""
if [ -n "$KNOCK_USER_IDS" ] && [ "$KNOCK_USER_COUNT" -gt 0 ]; then
    # Convert UUIDs to PostgreSQL array format
    UUID_ARRAY=$(echo "$KNOCK_USER_IDS" | sed "s/^/'/;s/$/'/" | tr '\n' ',' | sed 's/,$//')
    EXCLUSION_CLAUSE="AND p.person_id NOT IN (SELECT * FROM UNNEST(ARRAY[$UUID_ARRAY]::uuid[]))"
fi

# Step 3: Fetch users from PostgreSQL
echo -e "\n${BLUE}Fetching users from PostgreSQL...${NC}"

# Set PGPASSWORD for psql
export PGPASSWORD="$DB_PASSWORD"

# Build SQL query
SQL_QUERY="SELECT DISTINCT
    p.email,
    p.person_id,
    p.preferred_language,
    p.first_name,
    p.middle_name,
    p.last_name,
    ph.phone_number
FROM
    \"core\".\"person\" AS p
LEFT JOIN
    \"core\".\"phone\" AS ph
    ON ph.person_id = p.person_id
WHERE
    p.email IS NOT NULL
    AND p.active = TRUE
    AND p.is_external = FALSE
    AND (p.email LIKE '%rentpure.com%' OR p.email LIKE '%purepm.co%')
    $EXCLUSION_CLAUSE
ORDER BY
    p.email ASC
LIMIT 1000;"

# Execute query and get results in CSV format
PG_USERS_CSV=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
    -t -A -F$'\t' -c "$SQL_QUERY" 2>&1)

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to query PostgreSQL${NC}"
    echo "$PG_USERS_CSV"
    exit 1
fi

# Count PostgreSQL users
PG_USER_COUNT=$(echo "$PG_USERS_CSV" | grep -c . || echo "0")
echo -e "${GREEN}Fetched $PG_USER_COUNT users from PostgreSQL (excluding $KNOCK_USER_COUNT Knock user IDs)${NC}"

if [ "$PG_USER_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}No new users to sync${NC}"
    exit 0
fi

# Display PostgreSQL users table
echo -e "\n${GREEN}PostgreSQL Users to Sync:${NC}"
echo -e "Email\tName\tPerson ID\tPreferred Language\tPhone Number" | column -t -s $'\t'
echo "$PG_USERS_CSV" | while IFS=$'\t' read -r email person_id preferred_language first_name middle_name last_name phone_number; do
    # Construct full name
    name_parts=""
    [ -n "$first_name" ] && name_parts="$first_name"
    [ -n "$middle_name" ] && name_parts="$name_parts $middle_name"
    [ -n "$last_name" ] && name_parts="$name_parts $last_name"
    name=$(echo "$name_parts" | xargs)
    [ -z "$name" ] && name=""
    
    echo -e "$email\t$name\t$person_id\t${preferred_language:-}\t${phone_number:-}" | column -t -s $'\t'
done

# Step 4: Build JSON payload for bulk identify
echo -e "\n${BLUE}Preparing bulk identify payload...${NC}"

# Create temporary file for JSON payload
JSON_PAYLOAD=$(mktemp)

# Build users array
echo '{"users":[' > "$JSON_PAYLOAD"
FIRST=true
echo "$PG_USERS_CSV" | while IFS=$'\t' read -r email person_id preferred_language first_name middle_name last_name phone_number; do
    # Construct full name
    name_parts=""
    [ -n "$first_name" ] && name_parts="$first_name"
    [ -n "$middle_name" ] && name_parts="$name_parts $middle_name"
    [ -n "$last_name" ] && name_parts="$name_parts $last_name"
    name=$(echo "$name_parts" | xargs)
    
    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        echo -n ',' >> "$JSON_PAYLOAD"
    fi
    
    # Build user object
    echo -n "{\"id\":\"$person_id\",\"email\":\"$email\"" >> "$JSON_PAYLOAD"
    [ -n "$name" ] && echo -n ",\"name\":\"$name\"" >> "$JSON_PAYLOAD"
    [ -n "$phone_number" ] && echo -n ",\"phone_number\":\"$phone_number\"" >> "$JSON_PAYLOAD"
    echo -n '}' >> "$JSON_PAYLOAD"
done
echo ']}' >> "$JSON_PAYLOAD"

# Step 5: Send bulk identify request to Knock API
echo -e "${BLUE}Sending users to Knock API...${NC}"

BULK_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $KNOCK_API_KEY" \
    -d @"$JSON_PAYLOAD" \
    "https://api.knock.app/v1/users/bulk/identify")

HTTP_CODE=$(echo "$BULK_RESPONSE" | tail -n1)
BULK_BODY=$(echo "$BULK_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
    echo -e "${RED}Error: Failed to bulk identify users (HTTP $HTTP_CODE)${NC}"
    echo "$BULK_BODY"
    rm -f "$JSON_PAYLOAD"
    exit 1
fi

echo -e "${GREEN}Successfully sent $PG_USER_COUNT users to Knock API${NC}"
if command -v jq >/dev/null 2>&1; then
    echo "Response:" | jq '.' <<< "$BULK_BODY"
else
    echo "Response: $BULK_BODY"
fi

# Clean up temporary file
rm -f "$JSON_PAYLOAD"

# Step 6: Write PostgreSQL users to log file
PG_LOG="logs/${DATE_STR}_postgres_users.log"
{
    echo "=== $DATE ==="
    echo -e "email\tperson_id\tname\tpreferred_language\tphone_number"
    echo "$PG_USERS_CSV" | while IFS=$'\t' read -r email person_id preferred_language first_name middle_name last_name phone_number; do
        name_parts=""
        [ -n "$first_name" ] && name_parts="$first_name"
        [ -n "$middle_name" ] && name_parts="$name_parts $middle_name"
        [ -n "$last_name" ] && name_parts="$name_parts $last_name"
        name=$(echo "$name_parts" | xargs)
        [ -z "$name" ] && name=""
        echo -e "$email\t$person_id\t$name\t${preferred_language:-}\t${phone_number:-}"
    done
} > "$PG_LOG"

echo -e "\n${GREEN}$PG_USER_COUNT users written to $PG_LOG${NC}"
echo -e "\n${GREEN}✓ Sync completed successfully!${NC}"
