#!/bin/bash
export LC_ALL=C
export LANG=C

# Function to generate a random 16-character string
generate_random_string() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16
}

# Create or clear the flags.env file
> flags.env

echo "Generating flags.env from docker compose config..."

# Process the docker compose output
docker compose config | grep "FLAG_" | sed 's/^[[:space:]]*//' | while IFS=: read -r flag_name flag_value; do
    # Clean up the flag value (remove leading/trailing spaces)
    flag_value=$(echo "$flag_value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Generate unique random string for this flag
    random_string=$(generate_random_string)
    
    # Replace _dummy with random string
    new_flag_value=$(echo "$flag_value" | sed "s/_dummy/_$random_string/g")
    
    # Write to flags.env file
    echo "${flag_name}=${new_flag_value}" >> flags.env
done

echo "Done! Generated flags.env:"
echo "=========================="
cat flags.env
