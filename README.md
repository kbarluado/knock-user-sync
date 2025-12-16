# PM Hub to Knock User Sync

Bulk syncs existing PM Hub users from PostgreSQL to Knock API, excluding users already present in Knock.

**Task:** [PMHUB-26082](https://purepm.atlassian.net/browse/PMHUB-26082)

## Requirements

- `curl` - HTTP client for API calls
- `psql` - PostgreSQL client
- `jq` - JSON parser (recommended, script works without it)

### Installing Requirements

**macOS:**
```bash
brew install postgresql jq
```


### Fixing psql PATH (macOS)

If `psql` is installed but not found, add it to your PATH:

```bash
# For postgresql@15
echo 'export PATH="/opt/homebrew/opt/postgresql@15/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# Or for Intel Macs
echo 'export PATH="/usr/local/opt/postgresql@15/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Verify installation:
```bash
psql --version
```

## Setup

1. Create a `.env` file in the project root:
```bash
KNOCK_API_KEY=your_knock_api_key
DB_HOST=your_db_host
DB_PORT=5432
DB_NAME=your_database_name
DB_USER=your_db_user
DB_PASSWORD=your_db_password
```

2. Make the script executable:
```bash
chmod +x sync-users.sh
```

## Usage

```bash
./sync-users.sh
```

The script will:
1. Fetch existing users from Knock API
2. Query PostgreSQL for PM Hub users (excluding those already in Knock)
3. Bulk identify new users to Knock API
4. Generate date-based log files in `logs/` directory

## Output

- Console output with user tables and sync status
- Log files: `logs/YYYY-MM-DD_knock_users.log` and `logs/YYYY-MM-DD_postgres_users.log`

