use bls12_381_plus::{pairing, G1Affine, G1Projective, G2Affine, G2Projective, Gt, Scalar};
use blst::{
    blst_bendian_from_fp, blst_fp, blst_fp2, blst_fp_from_bendian, blst_map_to_g1, blst_map_to_g2,
    blst_p1, blst_p1_affine, blst_p1_to_affine, blst_p2, blst_p2_affine, blst_p2_to_affine,
};
use group::Curve;
use rustler::Binary;
use std::convert::TryInto;

const FP_PADDED_BYTES: usize = 64;
const FP_BYTES: usize = 48;
const G1_PADDED_BYTES: usize = 128;
const G1_BYTES: usize = 96;
const G2_PADDED_BYTES: usize = 256;
const G2_BYTES: usize = 192;
const G1_MSM_PAIR_BYTES: usize = 160;
const G2_MSM_PAIR_BYTES: usize = 288;
const PAIRING_PAIR_BYTES: usize = 384;
const TRUE_WORD: [u8; 32] = {
    let mut out = [0u8; 32];
    out[31] = 1;
    out
};

rustler::init!("Elixir.EEVM.Precompiles.Bls12381.Nif");

#[derive(Debug)]
enum BlsError {
    InvalidInput,
    InvalidPoint,
}

impl rustler::Encoder for BlsError {
    fn encode<'a>(&self, env: rustler::Env<'a>) -> rustler::Term<'a> {
        let atom = match self {
            Self::InvalidInput => {
                rustler::types::atom::Atom::from_str(env, "invalid_input").unwrap()
            }
            Self::InvalidPoint => {
                rustler::types::atom::Atom::from_str(env, "invalid_point").unwrap()
            }
        };

        (rustler::types::atom::error(), atom).encode(env)
    }
}

#[rustler::nif(name = "g1_add")]
fn g1_add(input: Binary<'_>) -> Result<(rustler::types::atom::Atom, Vec<u8>), BlsError> {
    if input.len() != 2 * G1_PADDED_BYTES {
        return Err(BlsError::InvalidInput);
    }

    let left = decode_g1_unchecked(&input[..G1_PADDED_BYTES])?;
    let right = decode_g1_unchecked(&input[G1_PADDED_BYTES..])?;
    let result = left + right;

    Ok((rustler::types::atom::ok(), encode_g1_projective(&result)))
}

#[rustler::nif(name = "g1_msm")]
fn g1_msm(input: Binary<'_>) -> Result<(rustler::types::atom::Atom, Vec<u8>), BlsError> {
    if input.is_empty() || input.len() % G1_MSM_PAIR_BYTES != 0 {
        return Err(BlsError::InvalidInput);
    }

    let mut acc = G1Projective::IDENTITY;

    for chunk in input.chunks_exact(G1_MSM_PAIR_BYTES) {
        let point = decode_g1_checked(&chunk[..G1_PADDED_BYTES])?;
        let scalar = decode_scalar(&chunk[G1_PADDED_BYTES..])?;
        acc += point * scalar;
    }

    Ok((rustler::types::atom::ok(), encode_g1_projective(&acc)))
}

#[rustler::nif(name = "g2_add")]
fn g2_add(input: Binary<'_>) -> Result<(rustler::types::atom::Atom, Vec<u8>), BlsError> {
    if input.len() != 2 * G2_PADDED_BYTES {
        return Err(BlsError::InvalidInput);
    }

    let left = decode_g2_unchecked(&input[..G2_PADDED_BYTES])?;
    let right = decode_g2_unchecked(&input[G2_PADDED_BYTES..])?;
    let result = left + right;

    Ok((rustler::types::atom::ok(), encode_g2_projective(&result)))
}

#[rustler::nif(name = "g2_msm")]
fn g2_msm(input: Binary<'_>) -> Result<(rustler::types::atom::Atom, Vec<u8>), BlsError> {
    if input.is_empty() || input.len() % G2_MSM_PAIR_BYTES != 0 {
        return Err(BlsError::InvalidInput);
    }

    let mut acc = G2Projective::IDENTITY;

    for chunk in input.chunks_exact(G2_MSM_PAIR_BYTES) {
        let point = decode_g2_checked(&chunk[..G2_PADDED_BYTES])?;
        let scalar = decode_scalar(&chunk[G2_PADDED_BYTES..])?;
        acc += point * scalar;
    }

    Ok((rustler::types::atom::ok(), encode_g2_projective(&acc)))
}

#[rustler::nif(name = "pairing")]
fn pairing_check(input: Binary<'_>) -> Result<(rustler::types::atom::Atom, Vec<u8>), BlsError> {
    if input.is_empty() || input.len() % PAIRING_PAIR_BYTES != 0 {
        return Err(BlsError::InvalidInput);
    }

    let mut acc = Gt::IDENTITY;

    for chunk in input.chunks_exact(PAIRING_PAIR_BYTES) {
        let g1 = decode_g1_checked_affine(&chunk[..G1_PADDED_BYTES])?;
        let g2 = decode_g2_checked_affine(&chunk[G1_PADDED_BYTES..])?;
        acc = Gt::product(&acc, &pairing(&g1, &g2));
    }

    let output = if acc == Gt::IDENTITY {
        TRUE_WORD
    } else {
        [0u8; 32]
    };
    Ok((rustler::types::atom::ok(), output.to_vec()))
}

#[rustler::nif]
fn map_fp_to_g1(input: Binary<'_>) -> Result<(rustler::types::atom::Atom, Vec<u8>), BlsError> {
    if input.len() != FP_PADDED_BYTES {
        return Err(BlsError::InvalidInput);
    }

    let fp = decode_blst_fp(&input)?;
    let mut point = blst_p1::default();

    unsafe {
        blst_map_to_g1(&mut point, &fp, std::ptr::null());
    }

    Ok((rustler::types::atom::ok(), encode_blst_g1(&point)))
}

#[rustler::nif]
fn map_fp2_to_g2(input: Binary<'_>) -> Result<(rustler::types::atom::Atom, Vec<u8>), BlsError> {
    if input.len() != 2 * FP_PADDED_BYTES {
        return Err(BlsError::InvalidInput);
    }

    let fp2 = decode_blst_fp2(&input)?;
    let mut point = blst_p2::default();

    unsafe {
        blst_map_to_g2(&mut point, &fp2, std::ptr::null());
    }

    Ok((rustler::types::atom::ok(), encode_blst_g2(&point)))
}

fn decode_scalar(input: &[u8]) -> Result<Scalar, BlsError> {
    let scalar_bytes: [u8; 32] = input.try_into().map_err(|_| BlsError::InvalidInput)?;
    let mut wide = [0u8; 64];

    for (idx, byte) in scalar_bytes.iter().rev().enumerate() {
        wide[idx] = *byte;
    }

    Ok(Scalar::from_bytes_wide(&wide))
}

fn decode_g1_checked(input: &[u8]) -> Result<G1Projective, BlsError> {
    decode_g1_with(input, true).map(G1Projective::from)
}

fn decode_g1_checked_affine(input: &[u8]) -> Result<G1Affine, BlsError> {
    decode_g1_with(input, true)
}

fn decode_g1_unchecked(input: &[u8]) -> Result<G1Projective, BlsError> {
    decode_g1_with(input, false).map(G1Projective::from)
}

fn decode_g1_with(input: &[u8], subgroup_check: bool) -> Result<G1Affine, BlsError> {
    if input.iter().all(|byte| *byte == 0) {
        return Ok(G1Affine::identity());
    }

    let encoded = encode_g1_for_library(input)?;
    let point = if subgroup_check {
        G1Affine::from_uncompressed(&encoded)
    } else {
        G1Affine::from_uncompressed_unchecked(&encoded)
    };

    if bool::from(point.is_some()) {
        Ok(point.unwrap())
    } else {
        Err(BlsError::InvalidPoint)
    }
}

fn decode_g2_checked(input: &[u8]) -> Result<G2Projective, BlsError> {
    decode_g2_with(input, true).map(G2Projective::from)
}

fn decode_g2_checked_affine(input: &[u8]) -> Result<G2Affine, BlsError> {
    decode_g2_with(input, true)
}

fn decode_g2_unchecked(input: &[u8]) -> Result<G2Projective, BlsError> {
    decode_g2_with(input, false).map(G2Projective::from)
}

fn decode_g2_with(input: &[u8], subgroup_check: bool) -> Result<G2Affine, BlsError> {
    if input.iter().all(|byte| *byte == 0) {
        return Ok(G2Affine::identity());
    }

    let encoded = encode_g2_for_library(input)?;
    let point = if subgroup_check {
        G2Affine::from_uncompressed(&encoded)
    } else {
        G2Affine::from_uncompressed_unchecked(&encoded)
    };

    if bool::from(point.is_some()) {
        Ok(point.unwrap())
    } else {
        Err(BlsError::InvalidPoint)
    }
}

fn encode_g1_projective(point: &G1Projective) -> Vec<u8> {
    let affine = point.to_affine();

    if bool::from(affine.is_identity()) {
        return vec![0u8; G1_PADDED_BYTES];
    }

    let uncompressed = affine.to_uncompressed();
    let mut out = vec![0u8; G1_PADDED_BYTES];

    out[16..64].copy_from_slice(&uncompressed[..48]);
    out[80..128].copy_from_slice(&uncompressed[48..96]);
    out
}

fn encode_g2_projective(point: &G2Projective) -> Vec<u8> {
    let affine = point.to_affine();

    if bool::from(affine.is_identity()) {
        return vec![0u8; G2_PADDED_BYTES];
    }

    let uncompressed = affine.to_uncompressed();
    let mut out = vec![0u8; G2_PADDED_BYTES];

    out[16..64].copy_from_slice(&uncompressed[48..96]);
    out[80..128].copy_from_slice(&uncompressed[..48]);
    out[144..192].copy_from_slice(&uncompressed[144..192]);
    out[208..256].copy_from_slice(&uncompressed[96..144]);
    out
}

fn encode_g1_for_library(input: &[u8]) -> Result<[u8; G1_BYTES], BlsError> {
    if input.len() != G1_PADDED_BYTES {
        return Err(BlsError::InvalidInput);
    }

    let x = strip_fp_padding(&input[..FP_PADDED_BYTES])?;
    let y = strip_fp_padding(&input[FP_PADDED_BYTES..G1_PADDED_BYTES])?;
    let mut out = [0u8; G1_BYTES];

    out[..48].copy_from_slice(&x);
    out[48..96].copy_from_slice(&y);
    Ok(out)
}

fn encode_g2_for_library(input: &[u8]) -> Result<[u8; G2_BYTES], BlsError> {
    if input.len() != G2_PADDED_BYTES {
        return Err(BlsError::InvalidInput);
    }

    let x_c0 = strip_fp_padding(&input[..FP_PADDED_BYTES])?;
    let x_c1 = strip_fp_padding(&input[FP_PADDED_BYTES..2 * FP_PADDED_BYTES])?;
    let y_c0 = strip_fp_padding(&input[2 * FP_PADDED_BYTES..3 * FP_PADDED_BYTES])?;
    let y_c1 = strip_fp_padding(&input[3 * FP_PADDED_BYTES..G2_PADDED_BYTES])?;
    let mut out = [0u8; G2_BYTES];

    out[..48].copy_from_slice(&x_c1);
    out[48..96].copy_from_slice(&x_c0);
    out[96..144].copy_from_slice(&y_c1);
    out[144..192].copy_from_slice(&y_c0);
    Ok(out)
}

fn strip_fp_padding(input: &[u8]) -> Result<[u8; FP_BYTES], BlsError> {
    let bytes: [u8; FP_PADDED_BYTES] = input.try_into().map_err(|_| BlsError::InvalidInput)?;

    if bytes[..16].iter().any(|byte| *byte != 0) {
        return Err(BlsError::InvalidInput);
    }

    Ok(bytes[16..].try_into().unwrap())
}

fn decode_blst_fp(input: &[u8]) -> Result<blst_fp, BlsError> {
    let bytes = strip_fp_padding(input)?;
    let mut fp = blst_fp::default();

    unsafe {
        blst_fp_from_bendian(&mut fp, bytes.as_ptr());
    }

    let mut canonical = [0u8; FP_BYTES];

    unsafe {
        blst_bendian_from_fp(canonical.as_mut_ptr(), &fp);
    }

    if canonical != bytes {
        return Err(BlsError::InvalidInput);
    }

    Ok(fp)
}

fn decode_blst_fp2(input: &[u8]) -> Result<blst_fp2, BlsError> {
    if input.len() != 2 * FP_PADDED_BYTES {
        return Err(BlsError::InvalidInput);
    }

    Ok(blst_fp2 {
        fp: [
            decode_blst_fp(&input[..FP_PADDED_BYTES])?,
            decode_blst_fp(&input[FP_PADDED_BYTES..])?,
        ],
    })
}

fn encode_blst_g1(point: &blst_p1) -> Vec<u8> {
    let mut affine = blst_p1_affine::default();
    let mut x = [0u8; FP_BYTES];
    let mut y = [0u8; FP_BYTES];

    unsafe {
        blst_p1_to_affine(&mut affine, point);
        blst_bendian_from_fp(x.as_mut_ptr(), &affine.x);
        blst_bendian_from_fp(y.as_mut_ptr(), &affine.y);
    }

    let mut out = vec![0u8; G1_PADDED_BYTES];
    out[16..64].copy_from_slice(&x);
    out[80..128].copy_from_slice(&y);
    out
}

fn encode_blst_g2(point: &blst_p2) -> Vec<u8> {
    let mut affine = blst_p2_affine::default();
    let mut x_c0 = [0u8; FP_BYTES];
    let mut x_c1 = [0u8; FP_BYTES];
    let mut y_c0 = [0u8; FP_BYTES];
    let mut y_c1 = [0u8; FP_BYTES];

    unsafe {
        blst_p2_to_affine(&mut affine, point);
        blst_bendian_from_fp(x_c0.as_mut_ptr(), &affine.x.fp[0]);
        blst_bendian_from_fp(x_c1.as_mut_ptr(), &affine.x.fp[1]);
        blst_bendian_from_fp(y_c0.as_mut_ptr(), &affine.y.fp[0]);
        blst_bendian_from_fp(y_c1.as_mut_ptr(), &affine.y.fp[1]);
    }

    let mut out = vec![0u8; G2_PADDED_BYTES];
    out[16..64].copy_from_slice(&x_c0);
    out[80..128].copy_from_slice(&x_c1);
    out[144..192].copy_from_slice(&y_c0);
    out[208..256].copy_from_slice(&y_c1);
    out
}
