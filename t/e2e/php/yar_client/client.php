<?php
/**
 * PHP Yar Client — 场景1客户端（YAR → gRPC 方向，APISIX 版）
 *
 * 向 APISIX 发送 YAR 协议请求，APISIX 插件通过 yar2grpc_endpoint
 * 转换为 gRPC 调用，转发到 Go gRPC Server。
 *
 * 依赖：php-yar 扩展（pecl install yar）
 * 用法：php client.php
 *       php -d yar.packager=msgpack client.php  （覆盖打包器）
 */

$packager = getenv("YAR_PACKAGER") ?: "json";
$port = getenv("E2E_PORT_APISIX_YAR2GRPC") ?: "1995";
$client = new Yar_Client("http://127.0.0.1:{$port}/api/calculator.Calculator");
$client->setOpt(YAR_OPT_PACKAGER, $packager);

$result_add = $client->add(15, 27);
echo "add(15, 27) = " . $result_add . "\n";
assert($result_add === 42, "Expected 42, got {$result_add}");

$result_sub = $client->subtract(100, 37);
echo "subtract(100, 37) = " . $result_sub . "\n";
assert($result_sub === 63, "Expected 63, got {$result_sub}");

echo "Scenario 1 (PHP Yar → APISIX → Go gRPC): PASS\n";
