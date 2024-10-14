import QuickRoute.time;

import ballerina/file;
import ballerina/io;
import ballerina/regex;

public function deleteImageFile(string filePath) returns boolean|error {
    boolean fileExists = check file:test(filePath, file:EXISTS);
    if !fileExists {
        return false;
    }
    error? result = file:remove(filePath);
    if result is error {
        return false;
    }
    return true;
}

public function uploadImage(byte[] image, string path, string fileName) returns string|error|io:Error? {
    string newFileName = regex:replace(fileName, "\\s+", "_") + "_" + time:getUniqueIDByCurrentTime() + ".png";
    string uploadPath = "./uploads/" + path + newFileName;

    check io:fileWriteBytes(uploadPath, image);
    return path + newFileName;
}
