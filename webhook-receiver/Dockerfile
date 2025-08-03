# Use a minimal, secure Node.js image
FROM node:18-alpine

# Set the working directory inside the container
WORKDIR /usr/src/app

# Copy package.json and install dependencies
COPY package.json ./
RUN npm install --only=production

# Copy the rest of the application code
COPY index.js ./

# Expose the port the server will run on
EXPOSE 9000

# The command to start the server
CMD [ "node", "index.js" ]