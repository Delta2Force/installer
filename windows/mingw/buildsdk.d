//
// Convert MingGW-w64 definition files to COFF import librries
//
// Distributed under the Boost Software License, Version 1.0.
//   (See accompanying file LICENSE_1_0.txt or copy at
//         http://www.boost.org/LICENSE_1_0.txt)
//
// usage: buildsdk [x86|x64] [mingw-w64-folder] [output-folder]
//
// source files extracted from MinGW-w64:
// https://sourceforge.net/projects/mingw-w64/files/mingw-w64/mingw-w64-release/mingw-w64-v6.0.0.tar.bz2
//
// assumes dmd & VC tools cl, lib, link and ml installed and found through path
//  and configured to the appropriate architecture
//

import std.algorithm;
import std.array;
import std.ascii : isDigit;
import std.file;
import std.format : format;
import std.path;
import std.process;
import std.stdio;
import std.string;

version = verbose;

bool x64;
string[string] weakSymbols; // weak name => real name


void runShell(string cmd)
{
    version (verbose)
        writeln(cmd);
    const rc = executeShell(cmd);
    if (rc.status)
    {
        writeln("'", cmd, "' failed with status ", rc.status);
        writeln(rc.output);
        throw new Exception("'" ~ cmd ~ "' failed");
    }
}

alias LineTransformer = string delegate(const string line);
string patchLines(string inFile, string outFile, LineTransformer lineTransformer)
{
    const lines = std.file.readText(inFile).splitLines;

    bool transformed = false;
    const newLines = lines.map!((const string line)
    {
        const newLine = lineTransformer(line);
        if (newLine !is line)
            transformed = true;
        return newLine;
    }).array;

    if (!transformed)
        return inFile;

    version (verbose)
        writeln(`Patching file "` ~ inFile ~ `" to "` ~ outFile ~ `"`);

    std.file.write(outFile, newLines.join("\n"));
    return outFile;
}

// Preprocesses a 'foo.def.in' file to 'foo.def'.
void generateDef(string inFile, string outFile)
{
    const patchedInFile = outFile ~ ".in";
    const realInFile = patchLines(inFile, patchedInFile, (line)
    {
        // The MinGW-w64 .def.in files use 'F_X86_ANY(DATA)' to hide functions
        // overridden by the MinGW runtime, primarily math functions.
        return line.replace(" F_X86_ANY(DATA)", "");
    });

    const includeDir = buildPath(inFile.dirName.dirName, "def-include");
    const archDefine = x64 ? "DEF_X64" : "DEF_I386";
    runShell(`cl /EP /D` ~ archDefine ~ `=1 "/I` ~ includeDir ~ `" "` ~ realInFile ~ `" > "` ~ outFile ~ `"`);
}

void sanitizeDef(string defFile)
{
    patchLines(defFile, defFile, (line)
    {
        if (line.length == 0 || line[0] == ';')
            return line;

        if (line == "LIBRARY vcruntime140_app")
            return `LIBRARY "vcruntime140.dll"`;

        // The MinGW-w64 .def files specify weak external symbols as 'alias == realName'.
        const i = line.indexOf("==");
        if (i > 0)
        {
            const weakName = strip(line[0 .. i]);
            const realName = strip(line[i+2 .. $]);

            if (weakName.indexOf(' ') < 0 && realName.indexOf(' ') < 0)
            {
                weakSymbols[weakName] = realName;
                return ";" ~ line;
            }
        }

        // The MinGW runtime apparently replaces ceil(f)/floor(f) and hides the original functions via DATA.
        if (line == "ceil DATA" || line == "ceilf DATA" ||
            line == "floor DATA" || line == "floorf DATA")
            return line[0 .. $-5];

        // MinGW apparently also replaces ucrtbase.dll's '_tzset'.
        if (line == "_tzset DATA")
            return "_tzset";

        // Don't export function 'atexit'; we have our own in msvc_atexit.c.
        if (line == "atexit")
            return ";atexit";

        // An apparent bug in lib32/shell32.def (there's 'ExtractIconW@12' too).
        if (line == "ExtractIconW@")
            return ";ExtractIconW@";

        return line;
    });
}

void copyDefs(string inDir, string outDir)
{
    mkdirRecurse(outDir);

    foreach (f; std.file.dirEntries(inDir, SpanMode.shallow))
    {
        const path = f.name;
        const lowerPath = toLower(path);
        string outFile;

        if (lowerPath.endsWith(".def.in"))
        {
            auto base = baseName(path)[0 .. $-7];
            if (base == "vcruntime140_app")
                base = "vcruntime140";

            outFile = buildPath(outDir, base ~ ".def");
            generateDef(path, outFile);
        }
        else if (lowerPath.endsWith(".def"))
        {
            outFile = buildPath(outDir, baseName(path));
            std.file.copy(path, outFile);
        }

        if (outFile !is null)
            sanitizeDef(outFile);
    }
}

void def2implib(string defFile)
{
    if (!x64)
    {
        if (defWithStdcallMangling2implib(defFile))
            return;
    }

    const libFile = setExtension(defFile, ".lib");
    const arch = x64 ? "X64" : "X86";
    runShell(`lib /MACHINE:` ~ arch ~ ` "/DEF:` ~ defFile ~ `" "/OUT:` ~ libFile ~ `"`);
    std.file.remove(setExtension(defFile, ".exp"));
}

void defs2implibs(string dir)
{
    foreach (f; std.file.dirEntries(dir, SpanMode.shallow))
    {
        const path = f.name;
        if (toLower(path).endsWith(".def"))
            def2implib(path);
    }
}

void cl(string outObj, string args)
{
    runShell(`cl /c /Zl "/Fo` ~ outObj ~ `" ` ~ args);
}

string quote(string arg)
{
    return `"` ~ arg ~ `"`;
}

/**
 * x86: the WinAPI symbol names in the .def files are stdcall-mangled
 * (trailing `@<N>`). These mangled names are required in the import
 * library, but the names of the DLL exports don't feature the stdcall
 * suffix.
 * `lib /DEF` doesn't support the required renaming functionality, so
 * we have to go through compiling a D file with the symbols and
 * building a DLL with renamed exports to get the appropriate import
 * library.
 */
bool defWithStdcallMangling2implib(string defFile)
{
    import std.regex : ctRegex, matchFirst;

    string[] functions;
    string[] fields;
    bool hasRenamedStdcall = false;

    patchLines(defFile, defFile, (line)
    {
        if (line.length == 0 || line[0] == ';' ||
            line.startsWith("LIBRARY ") || line.startsWith("EXPORTS"))
            return line;

        if (line.endsWith(" DATA"))
        {
            fields ~= line[0 .. $-5];
            return line;
        }

        // include fastcall mangle (like stdcall, with additional leading '@')
        enum re = ctRegex!r"^@?([a-zA-Z0-9_]+)(@[0-9]+)";
        if (const m = matchFirst(line, re))
        {
            string lineSuffix = line[m[0].length .. $];
            if (lineSuffix.startsWith(m[2])) // e.g., 'JetAddColumnA@28@28'
            {
                /**
                 * Actually not to be renamed, symbol is exported in mangled form.
                 * Treat it like 'JetAddColumnA@28' though, because some libraries
                 * export the same function as both 'JetAddColumnA' and 'JetAddColumnA@28',
                 * and I don't know how to replicate that with our approach.
                 */
                lineSuffix = lineSuffix[m[2].length .. $];
            }

            assert(!lineSuffix.startsWith("=")); // renamings not supported

            hasRenamedStdcall = true;
            functions ~= m[1];
            // keep the line suffix (e.g., ' @100' => ordinal 100)
            return m[0] ~ "=" ~ m[1] ~ lineSuffix;
        }

        const firstSpaceIndex = line.indexOf(' ');
        const strippedLine = firstSpaceIndex < 0 ? line : line[0 .. firstSpaceIndex];
        const equalsIndex = strippedLine.indexOf('=');
        const functionName = equalsIndex > 0 ? strippedLine[equalsIndex+1 .. $] : strippedLine;
        functions ~= functionName;
        return line;
    });

    if (!hasRenamedStdcall)
        return false;

    string src = "module dummy;\n";
    alias Emitter = string delegate();
    void emitOnce(ref bool[string] emittedSymbols, string symbolName, Emitter emitter)
    {
        if (symbolName !in emittedSymbols)
        {
            src ~= emitter() ~ "\n";
            emittedSymbols[symbolName] = true;
        }
    }

    bool[string] emittedFunctions;
    foreach (i, name; functions)
    {
        emitOnce(emittedFunctions, name, ()
        {
            const linkage = name[0] == '?' ? "C++" : "C";
            return `pragma(mangle, "%s") extern(%s) void func%d() {}`.format(name, linkage, i);
        });
    }

    bool[string] emittedFields;
    foreach (i, name; fields)
    {
        emitOnce(emittedFields, name, ()
        {
            const linkage = name[0] == '_' ? "C" : "C++";
            return `pragma(mangle, "%s") extern(%s) __gshared int field%d;`.format(name, linkage, i);
        });
    }

    const dFile = setExtension(defFile, ".d");
    const objFile = setExtension(defFile, ".obj");
    const dllFile = setExtension(defFile, ".dll");

    std.file.write(dFile, src);
    runShell(`dmd -c -betterC -m32mscoff "-of=` ~ objFile ~ `" ` ~ quote(dFile));
    runShell("link /NOD /NOENTRY /DLL " ~ quote(objFile) ~ ` "/OUT:` ~ dllFile ~ `" "/DEF:` ~ defFile ~ `"`);

    std.file.remove(dFile);
    std.file.remove(objFile);
    std.file.remove(dllFile);
    std.file.remove(setExtension(dllFile, ".exp"));

    return true;
}

void c2lib(string outDir, string cFile)
{
    const obj = buildPath(outDir, baseName(cFile).setExtension(".obj"));
    const lib = setExtension(obj, ".lib");
    cl(obj, quote(cFile));
    runShell(`lib /MACHINE:` ~ (x64 ? "X64" : "X86") ~ ` "/OUT:` ~ lib ~ `" "` ~ obj ~ `"`);
    std.file.remove(obj);
}

void buildMsvcrt(string outDir)
{
    const arch = x64 ? "X64" : "X86";
    foreach (lib; std.file.dirEntries(outDir, "*.lib", SpanMode.shallow))
    {
        const lowerBase = toLower(baseName(lib.name));
        if (!(lowerBase.startsWith("msvcr") || lowerBase.startsWith("vcruntime")))
            continue;

        // parse version from filename (e.g., 140 for VC++ 2015)
        const versionStart = lowerBase[0] == 'm' ? 5 : 9;
        const versionLength = lowerBase[versionStart .. $].countUntil!(c => !isDigit(c));
        const msvcrtVersion = versionLength == 0 ? "0" : lowerBase[versionStart .. versionStart+versionLength];

        string[] objs;
        void addObj(string objFilename, string args)
        {
            const obj = buildPath(outDir, objFilename);
            cl(obj, "/DMSVCRT_VERSION=" ~ msvcrtVersion ~ " " ~ args);
            objs ~= obj;
        }

        // compile some additional objects
        foreach (i; 0 .. 3)
            addObj(format!"msvcrt_stub%d.obj"(i), format!"/D_APPTYPE=%d msvcrt_stub.c"(i));
        addObj("msvcrt_data.obj", "msvcrt_data.c");
        addObj("msvcrt_atexit.obj", "msvcrt_atexit.c");
        if (!x64)
        {
            const obj = buildPath(outDir, "msvcrt_abs.obj");
            runShell(`ml /c /safeseh "/Fo` ~ obj ~ `" msvcrt_abs.asm`);
            objs ~= obj;
        }

        // merge them into the library
        runShell(`lib /MACHINE:` ~ arch ~ ` "` ~ lib.name ~ `" ` ~ objs.map!quote.join(" "));

        foreach (obj; objs)
            std.file.remove(obj);
    }
}

void buildOldnames(string outDir)
{
    const cPrefix = x64 ? "" : "_";
    const oldnames_c =
        // access this __ref_oldnames symbol to drag in the generated linker directives (msvcrt_stub.c)
        "int __ref_oldnames;\n" ~
        weakSymbols.byKeyValue.map!(pair =>
            `__pragma(comment(linker, "/alternatename:` ~ cPrefix ~ pair.key ~ `=` ~ cPrefix ~ pair.value ~ `"));`
        ).join("\n");

    version (verbose)
        writeln("\nAuto-generated oldnames.c:\n----------\n", oldnames_c, "\n----------\n");

    const src = buildPath(outDir, "oldnames.c");
    std.file.write(src, oldnames_c);
    c2lib(outDir, src);
    std.file.remove(src);
}

void buildLegacyStdioDefinitions(string outDir)
{
    c2lib(outDir, "legacy_stdio_definitions.c");
}

// create empty uuid.lib (expected by dmd, but UUIDs already in druntime)
void buildUuid(string outDir)
{
    const src = buildPath(outDir, "uuid.c");
    std.file.write(src, "");
    c2lib(outDir, src);
    std.file.remove(src);
}

void main(string[] args)
{
    x64 = (args.length > 1 && args[1] == "x64");
    const mingwDir = (args.length > 2 ? args[2] : "mingw-w64");
    string outDir = x64 ? "lib64" : "lib32";
    if (args.length > 3)
        outDir = args[3];

    copyDefs(buildPath(mingwDir, "mingw-w64-crt", "lib-common"), outDir);
    copyDefs(buildPath(mingwDir, "mingw-w64-crt", "lib" ~ (x64 ? "64" : "32")), outDir);

    defs2implibs(outDir);

    buildMsvcrt(outDir);
    buildOldnames(outDir);
    buildLegacyStdioDefinitions(outDir);
    buildUuid(outDir);

    //version (verbose) {} else
        foreach (f; std.file.dirEntries(outDir, "*.def*", SpanMode.shallow))
            std.file.remove(f.name);
}
