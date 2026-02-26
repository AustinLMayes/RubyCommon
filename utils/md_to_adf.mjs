import fnTranslate from 'md-to-adf'

// Take command line arguments
const args = process.argv.slice(2)

// Get the markdown string
const md = args[0]

const translatedADF = fnTranslate( md )

// Print the ADF
console.log( JSON.stringify(translatedADF) )