var fs = require('fs')
const header = `const Order = {
`
const footer = `}

module.exports = Order;
`

let orderFileContent = header;
var lineReader = require('readline').createInterface({
    input: fs.createReadStream('raw.txt')
});

lineReader.on('line', function (line) {
    line = line.replace(' = []apitypes.Type{', ': [');
    line = line.replace('Name:', 'name:');
    line = line.replace('Type:', 'type:');
    if (line == '}') {
        line = '],';
    }
    orderFileContent += `    ${line}\n`;
});

lineReader.on('close', function () {
    orderFileContent += footer;
    fs.createWriteStream('order.js').write(orderFileContent);
    console.log('all done!!!');
});

