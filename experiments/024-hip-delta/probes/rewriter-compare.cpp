#include <string>
#include <regex>
#include <iostream>
#include <fstream>
#include <sstream>
#include <vector>
#include <algorithm>
#include <stdexcept>
using namespace std;
typedef runtime_error OpenMMException;
namespace old {
static bool isIdentifierChar(char c) {
    return isalnum((unsigned char) c) || c == '_';
}

static size_t findWord(const string& source, const string& word, size_t start) {
    size_t pos = source.find(word, start);
    while (pos != string::npos) {
        bool startsWord = (pos == 0 || !isIdentifierChar(source[pos-1]));
        bool endsWord = (pos+word.size() == source.size() || !isIdentifierChar(source[pos+word.size()]));
        if (startsWord && endsWord)
            return pos;
        pos = source.find(word, pos+1);
    }
    return string::npos;
}

static string replaceWord(const string& source, const string& word, const string& replacement) {
    string result;
    size_t pos = 0, found;
    while ((found = findWord(source, word, pos)) != string::npos) {
        result += source.substr(pos, found-pos)+replacement;
        pos = found+word.size();
    }
    return result+source.substr(pos);
}

/**
 * Rewrite one kernel parameter for Metal.  A pointer without an address space points to device
 * memory.  A value becomes a constant reference, so "real4 box" becomes "constant real4& _in_box",
 * and a statement copying it into a local variable with the original name is appended to the
 * prologue.  executeKernel() passes the arguments whose names start with _in_ by value.
 */
static string rewriteParameter(const string& param, string& prologue) {
    size_t first = param.find_first_not_of(" \t\r\n");
    if (first == string::npos)
        return param;
    size_t last = param.find_last_not_of(" \t\r\n");
    string declaration = param.substr(first, last-first+1);
    if (declaration.find_first_of("&[") != string::npos)
        return param;
    stringstream tokenStream(declaration);
    vector<string> tokens;
    string token;
    while (tokenStream >> token)
        if (token != "const")
            tokens.push_back(token);
    if (declaration.find('*') != string::npos) {
        for (string space : {"GLOBAL", "LOCAL", "LOCAL_ARG", "device", "threadgroup", "constant"})
            if (find(tokens.begin(), tokens.end(), space) != tokens.end())
                return param;
        return param.substr(0, first)+"device "+param.substr(first);
    }
    if (tokens.size() < 2)
        return param;
    string type;
    for (int i = 0; i < tokens.size()-1; i++)
        type += (i == 0 ? "" : " ")+tokens[i];
    const string& name = tokens.back();
    prologue += "    "+type+" "+name+" = _in_"+name+";\n";
    return param.substr(0, first)+"constant "+type+"& _in_"+name+param.substr(last+1);
}

/**
 * Rewrite the parameters of every kernel in a source file (see rewriteParameter()).  Preprocessor
 * directives inside a parameter list are copied into the prologue as well, so each copy statement
 * is compiled exactly when the parameter it reads is.
 */
static string rewriteKernelSignatures(const string& source) {
    string result;
    size_t pos = 0;
    size_t kernelStart;
    while ((kernelStart = min(findWord(source, "KERNEL", pos), findWord(source, "__global__", pos))) != string::npos) {
        size_t open = source.find('(', findWord(source, "void", kernelStart));
        if (open == string::npos)
            break;
        result += source.substr(pos, open+1-pos);
        string prologue, param;
        size_t i = open+1;
        int depth = 0;
        for (; i < source.size(); i++) {
            char c = source[i];
            if (c == '#') {
                size_t end = source.find('\n', i);
                string directive = source.substr(i, end-i);
                result += rewriteParameter(param, prologue)+directive;
                prologue += directive+"\n";
                param.clear();
                i = end-1;
            }
            else if (c == '(') {
                depth++;
                param += c;
            }
            else if (c == ')' && depth > 0) {
                depth--;
                param += c;
            }
            else if (c == ')' || (c == ',' && depth == 0)) {
                result += rewriteParameter(param, prologue)+c;
                param.clear();
                if (c == ')')
                    break;
            }
            else
                param += c;
        }
        size_t brace = source.find('{', i);
        if (brace == string::npos)
            throw OpenMMException("Error parsing kernel signature: "+source.substr(kernelStart, open-kernelStart));
        result += source.substr(i+1, brace+1-(i+1))+"\n"+prologue;
        pos = brace+1;
    }
    result += source.substr(pos);
    return result;
}
}
namespace nw {
static string rewriteParameter(const string& param, string& prologue) {
    smatch m;
    if (regex_search(param, regex("\\b(GLOBAL|LOCAL|LOCAL_ARG|device|threadgroup|constant)\\b|[&\\[]")))
        return param;
    if (param.find('*') != string::npos)
        return "device "+param;
    if (!regex_match(param, m, regex("\\s*(const\\s+)?(\\S.*?)\\s+(\\w+)((\\s+[A-Z_]+)*)\\s*")))
        return param;
    prologue += m[2].str()+" "+m[3].str()+" = _in_"+m[3].str()+";\n";
    return "constant "+m[2].str()+"& _in_"+m[3].str()+m[4].str();
}

static string rewriteKernelSignatures(const string& source) {
    string result;
    size_t pos = 0;
    smatch m;
    while (regex_search(source.begin()+pos, source.end(), m, regex("\\b(KERNEL|__global__)\\b.*?\\bvoid\\s+\\w+\\s*\\("))) {
        size_t i = pos+m.position()+m.length();
        result += source.substr(pos, i-pos);
        string prologue, param;
        for (int depth = 0; depth >= 0; i++) {
            if (source[i] == '#') {
                size_t end = source.find('\n', i)+1;
                result += rewriteParameter(param, prologue)+"\n"+source.substr(i, end-i);
                prologue += source.substr(i, end-i);
                param.clear();
                i = end-1;
                continue;
            }
            depth += (source[i] == '(')-(source[i] == ')');
            if (depth < 0 || (source[i] == ',' && depth == 0)) {
                result += rewriteParameter(param, prologue)+source[i];
                param.clear();
            }
            else
                param += source[i];
        }
        pos = source.find('{', i)+1;
        result += source.substr(i, pos-i)+"\n"+prologue;
    }
    return result+source.substr(pos);
}
}
int main(int argc, char** argv) {
    string mode = argv[1];
    for (int k = 2; k < argc; k++) {
        ifstream f(argv[k]); stringstream s; s << f.rdbuf(); string src = s.str();
        cout << "=== " << argv[k] << endl;
        if (mode == "old") cout << old::rewriteKernelSignatures(old::replaceWord(old::replaceWord(src, "thread", "_mmThread"), "long long", "long"));
        else cout << nw::rewriteKernelSignatures(regex_replace(regex_replace(src, regex("\\bthread\\b"), "_mmThread"), regex("\\blong long\\b"), "long"));
    }
}
